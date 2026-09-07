-- Makes pg_net dispatched work observable.
--
-- NOTE ON SCOPE: this is cross-brand infrastructure for the shared 28FS Supabase
-- project, not MUSTER-specific. It lives here because this repo is where it was
-- built. If a shared-infra repo exists, it belongs there.
--
-- Problem: pg_cron records whether its SQL statement ran. A job whose command is
-- `select net.http_post(...)` or `select x_invoke_fn(...)` returns a request id
-- immediately and the HTTP call happens later, out of band. So cron reports
-- "succeeded" no matter what the function does. Audited on this project:
-- 109 cron jobs, 92 active, 82 dispatch HTTP. All 82 were unmonitored, and six
-- were failing 100% of the time while cron showed an unbroken run of successes.
--
-- net._http_response makes this unrecoverable after the fact: it stores
-- id, status_code, content_type, headers, content, timed_out, error_msg, created
-- and NO url. Once a request completes there is nothing in Postgres tying a
-- failed response back to what it called.
--
-- Approach: capture at the queue, not at the caller. Only one *_invoke_fn wrapper
-- exists (s28_invoke_fn, 1 job); the other 71 inline net.http_post in the cron
-- command itself, in varied shapes. Rewriting those is risky and misses anything
-- dispatched outside cron. An AFTER INSERT trigger on net.http_request_queue sees
-- every pg_net request from any source, needs no change to any existing job, and
-- also captures direct outbound calls (OpenRouter, Telegram, GHL).
--
-- postgres does not own net.http_request_queue (supabase_admin does) but does hold
-- TRIGGER on it, which is what CREATE TRIGGER requires.

create table if not exists public.edge_invocations (
  id           bigint primary key,           -- pg_net request id
  url          text not null,
  fn           text,                         -- edge function slug when the url is one
  method       text,
  queued_at    timestamptz not null default now(),
  status_code  int,
  timed_out    boolean,
  error_msg    text,
  resolved_at  timestamptz,
  expired      boolean not null default false -- response pruned before we reconciled
);

comment on table public.edge_invocations is
  'One row per pg_net request, captured by trigger on net.http_request_queue and reconciled against net._http_response. Exists because pg_cron cannot see HTTP outcomes and net._http_response does not retain the url.';

create index if not exists edge_invocations_queued_at_idx on public.edge_invocations (queued_at desc);
create index if not exists edge_invocations_fn_idx        on public.edge_invocations (fn, queued_at desc);
create index if not exists edge_invocations_pending_idx   on public.edge_invocations (id) where resolved_at is null;

-- Operational data, not tenant data. Deny anon/authenticated outright; the
-- service role and postgres bypass RLS.
alter table public.edge_invocations enable row level security;
revoke all on public.edge_invocations from anon, authenticated;

-- Capture. This runs inside every pg_net dispatch in the project, so it must be
-- incapable of failing the insert it observes: any error here is swallowed and
-- the dispatch proceeds. Losing an observability row is always preferable to
-- breaking outbound HTTP for every brand at once.
create or replace function public.edge_invocations_capture()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
begin
  begin
    insert into public.edge_invocations (id, url, fn, method, queued_at)
    values (
      new.id,
      new.url,
      nullif(split_part(split_part(split_part(new.url, '/functions/v1/', 2), '?', 1), '/', 1), ''),
      new.method,
      now()
    )
    on conflict (id) do nothing;
  exception when others then
    null;
  end;
  return new;
end;
$fn$;

drop trigger if exists edge_invocations_capture_trg on net.http_request_queue;
create trigger edge_invocations_capture_trg
after insert on net.http_request_queue
for each row execute function public.edge_invocations_capture();

-- Reconcile. pg_net.ttl is 6 hours, so responses must be collected well inside
-- that window or the outcome is lost forever. Anything still unresolved after
-- 7 hours is marked expired rather than left looking pending forever.
create or replace function public.edge_invocations_reconcile(
  p_limit int default 20000,
  p_retain interval default '30 days'
)
returns table(resolved int, expired int, pruned int)
language plpgsql
security definer
set search_path = public, net, pg_temp
as $fn$
declare
  v_resolved int := 0;
  v_expired  int := 0;
  v_pruned   int := 0;
begin
  with pending as (
    select i.id from public.edge_invocations i
    where i.resolved_at is null
    order by i.id
    limit p_limit
  )
  update public.edge_invocations i
     set status_code = r.status_code,
         timed_out   = r.timed_out,
         error_msg   = r.error_msg,
         resolved_at = now()
    from net._http_response r
   where i.id = r.id
     and i.id in (select id from pending);
  get diagnostics v_resolved = row_count;

  update public.edge_invocations
     set expired = true,
         resolved_at = now(),
         error_msg = coalesce(error_msg, 'response pruned by pg_net before reconcile')
   where resolved_at is null
     and queued_at < now() - interval '7 hours';
  get diagnostics v_expired = row_count;

  delete from public.edge_invocations where queued_at < now() - p_retain;
  get diagnostics v_pruned = row_count;

  return query select v_resolved, v_expired, v_pruned;
end;
$fn$;

revoke all on function public.edge_invocations_reconcile(int, interval) from anon, authenticated;

-- Rollup. This is the thing to look at, and to alert on.
create or replace view public.v_edge_health as
select
  coalesce(i.fn, '(non-function url)') as fn,
  count(*)                                                              as calls_24h,
  count(*) filter (where i.status_code between 200 and 299)             as ok,
  count(*) filter (where i.status_code is not null
                     and (i.status_code < 200 or i.status_code >= 300)) as failed,
  count(*) filter (where i.timed_out)                                   as timed_out,
  count(*) filter (where i.resolved_at is null)                         as pending,
  count(*) filter (where i.expired)                                     as unknown_expired,
  round(
    100.0 * count(*) filter (where i.status_code is not null
                               and (i.status_code < 200 or i.status_code >= 300))
    / nullif(count(*) filter (where i.status_code is not null), 0)
  , 1)                                                                  as failure_pct,
  max(i.queued_at)                                                      as last_call,
  max(i.queued_at) filter (where i.status_code between 200 and 299)      as last_success
from public.edge_invocations i
where i.queued_at > now() - interval '24 hours'
group by 1;

comment on view public.v_edge_health is
  'Per-function HTTP outcomes over 24h for everything dispatched through pg_net. failure_pct ignores pending and expired rows so it is not diluted by requests with no known outcome.';

revoke all on public.v_edge_health from anon, authenticated;

-- Every 5 minutes, comfortably inside the 6 hour pg_net TTL.
select cron.schedule(
  'edge_invocations_reconcile',
  '*/5 * * * *',
  $cron$select public.edge_invocations_reconcile();$cron$
);
