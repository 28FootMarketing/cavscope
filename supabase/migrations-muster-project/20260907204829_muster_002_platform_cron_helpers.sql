-- Platform helpers ported from the shared hub (mgtmqucaldkaxvxglguw).
--
-- These are not MUSTER's own code -- they were house infrastructure on the
-- shared project, defined by 20260620220810_cron_error_log_and_safe_wrapper,
-- which lives in no repo. Six muster migrations call cron_safe_post, so a
-- blank project cannot replay them without this. Copied verbatim from
-- pg_get_functiondef on the source rather than rewritten.
--
-- What it buys: pg_cron records only whether the SQL ran. cron_safe_post
-- captures the pg_net request id so the HTTP outcome can be reconciled later,
-- and swallows dispatch errors into cron_error_log instead of failing the job.
-- That reconciliation is what public.edge_invocations (migration
-- 20260907055540) is built on.

create table if not exists public.cron_error_log (
  id              bigserial primary key,
  job_name        text not null,
  error_msg       text,
  response_status integer,
  response_body   text,
  fired_at        timestamptz default now()
);

create table if not exists public.cron_post_log (
  request_id bigint      not null,
  job_name   text        not null,
  fired_at   timestamptz not null default now()
);

create index if not exists cron_post_log_request_id_idx on public.cron_post_log (request_id);
create index if not exists cron_error_log_fired_at_idx  on public.cron_error_log (fired_at desc);

alter table public.cron_error_log enable row level security;
alter table public.cron_post_log  enable row level security;

create or replace function public.cron_safe_post(
  p_job_name text,
  p_url text,
  p_headers jsonb default '{"Content-Type": "application/json"}'::jsonb,
  p_body jsonb default '{}'::jsonb,
  p_timeout integer default 30000)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_request_id bigint;
begin
  select net.http_post(url := p_url, headers := p_headers, body := p_body, timeout_milliseconds := p_timeout) into v_request_id;
  insert into public.cron_post_log (request_id, job_name) values (v_request_id, p_job_name);
exception when others then
  insert into public.cron_error_log (job_name, error_msg) values (p_job_name, SQLERRM);
end $function$;

revoke all on function public.cron_safe_post(text, text, jsonb, jsonb, integer) from public, anon, authenticated;
grant execute on function public.cron_safe_post(text, text, jsonb, jsonb, integer) to service_role;
