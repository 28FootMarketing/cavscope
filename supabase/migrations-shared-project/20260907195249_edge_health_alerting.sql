-- Alerting on edge function health.
--
-- WHY THIS EXISTS
--
-- public.edge_invocations records the real HTTP outcome of every cron-dispatched
-- edge function call. Nothing read it. On 2026-09-07 a hand-written query against
-- it found 31 functions failing in 24 hours, including publish-due at 56 calls and
-- zero successes. None of that had produced an alert, because all three existing
-- health checkers deliberately skip exactly these jobs:
--
--   cora_cron_health_check()      ... where command not ilike '%cron_safe_post(%'
--   cora_job_health               ... same exclusion
--   jarvis_check_health_alerts()  ... "that helper can't detect its own success
--                                      and error-logs on every run, so its rows
--                                      are permanent noise, not signal"
--
-- That reasoning was correct when it was written: pg_cron only records whether the
-- SQL ran, and cron_safe_post's SQL always succeeds even when the HTTP call it
-- fires does not. The exclusion was the right call against the only evidence there
-- was. edge_invocations changed the evidence. This function is the other half --
-- it alerts on the HTTP outcome those checkers cannot see. Their exclusions stay
-- as they are; nothing here changes them.
--
-- DELIVERY
--
-- Signals go into public.jarvis_signals, which the existing jarvis-health-alerts /
-- cora-alert-dispatch path already delivers. No new secret, no new dispatcher, no
-- second notification channel to keep alive.
--
-- CATEGORY is 'edge_failure' and titles are 'Edge function failing: <fn>'. Both are
-- distinct from cron_failure and 'Cron job failing: %', so cora_cron_health_check's
-- open/resolve loop and this one never touch each other's rows.
--
-- TWO DETECTORS, because failure has two shapes here and one threshold cannot see
-- both:
--
--   A. FAILING -- a function called often enough to judge, failing at a rate that
--      matters: >= 5 calls in 24h and >= 25% of them failing. Catches the partial
--      failures, e.g. the brd-* 401 wave (22 of 56) that a "no successes lately"
--      rule would miss entirely because a third of the calls do succeed.
--
--   B. DEAD -- a function still being called but with no success at all in 48h,
--      and at least 2 failures in 72h. Catches the once-a-day jobs, which can
--      never reach a meaningful sample inside a 24h window. The 48h/2-failure
--      requirement is what keeps a single blip from paging anyone.
--
-- A FAILURE is a non-2xx response, a timeout, OR a request that expired with no
-- response. v_edge_health.failure_pct counts only non-2xx, so a function that does
-- nothing but time out reports failure_pct = NULL and looks healthy --
-- coach-enrich-dispatch (7 calls, 7 timeouts, 0 successes) is exactly that case
-- and is invisible in that column today.

create or replace function public.edge_health_check()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row record;
  v_title text;
  v_detail text;
  v_severity text;
  v_existing uuid;
  v_open_titles text[] := '{}';
begin
  for v_row in
    with inv as (
      select
        coalesce(i.fn, '(non-function url)') as fn,
        i.queued_at,
        i.status_code,
        i.timed_out,
        i.expired,
        i.error_msg,
        (i.status_code between 200 and 299)                                    as is_ok,
        (i.timed_out
          or i.expired
          or (i.status_code is not null and (i.status_code < 200 or i.status_code >= 300))) as is_fail
      from public.edge_invocations i
      where i.queued_at > now() - interval '72 hours'
    )
    select
      fn,
      count(*) filter (where queued_at > now() - interval '24 hours')                        as calls_24h,
      count(*) filter (where queued_at > now() - interval '24 hours' and is_ok)              as ok_24h,
      count(*) filter (where queued_at > now() - interval '24 hours' and is_fail)            as fail_24h,
      count(*) filter (where is_fail)                                                        as fail_72h,
      max(queued_at) filter (where is_ok)                                                    as last_success,
      max(queued_at)                                                                         as last_call,
      max(status_code) filter (where is_fail)                                                as worst_code,
      (array_agg(error_msg order by queued_at desc) filter (where error_msg is not null))[1]  as sample_error
    from inv
    group by fn
    having max(queued_at) > now() - interval '72 hours'
  loop
    -- 'fn' is null in edge_invocations for URLs that are not edge functions.
    -- They have no owner to route an alert to, so they are counted but not paged.
    continue when v_row.fn = '(non-function url)';

    v_severity := null;

    -- Detector A: failing at a rate that matters, on enough calls to be sure.
    if v_row.calls_24h >= 5
       and v_row.fail_24h * 100 >= v_row.calls_24h * 25 then
      v_severity := case
        when v_row.ok_24h = 0 then 'critical'
        when v_row.fail_24h * 100 >= v_row.calls_24h * 50 then 'high'
        -- Rate alone understates a busy function. 39% of 56 calls is 22 pieces of
        -- customer-facing work not delivered per day; that is not a "medium"
        -- because the other 61% happened to go through. Volume of failed work
        -- promotes a tier on its own.
        when v_row.fail_24h >= 20 then 'high'
        else 'medium'
      end;
      v_detail := format(
        '%s of %s calls failed in 24h (%s%%). Last success: %s. Worst status: %s.%s',
        v_row.fail_24h, v_row.calls_24h,
        round(100.0 * v_row.fail_24h / nullif(v_row.calls_24h, 0)),
        coalesce(v_row.last_success::text, 'none in 72h'),
        coalesce(v_row.worst_code::text, 'timeout/no response'),
        coalesce(' Error: ' || left(v_row.sample_error, 160), ''));

    -- Detector B: still being called, but nothing has worked in two days.
    elsif v_row.fail_72h >= 2
          and (v_row.last_success is null or v_row.last_success < now() - interval '48 hours') then
      v_severity := 'high';
      v_detail := format(
        'No successful call in 48h. %s failure(s) in 72h, last attempted %s. Worst status: %s.%s',
        v_row.fail_72h, v_row.last_call,
        coalesce(v_row.worst_code::text, 'timeout/no response'),
        coalesce(' Error: ' || left(v_row.sample_error, 160), ''));
    end if;

    continue when v_severity is null;

    v_title := 'Edge function failing: ' || v_row.fn;
    v_open_titles := v_open_titles || v_title;

    select id into v_existing
    from public.jarvis_signals
    where title = v_title and category = 'edge_failure' and status = 'open'
    limit 1;

    if v_existing is not null then
      update public.jarvis_signals
      set detail = v_detail, severity = v_severity
      where id = v_existing;
    else
      insert into public.jarvis_signals
        (venture_id, severity, category, title, detail, recommendation, action_route, status)
      values (
        null, v_severity, 'edge_failure', v_title, v_detail,
        'Query public.edge_invocations for this fn to see status_code, timed_out and error_msg per call. '
        || 'A 401 usually means a rotated or missing vault secret; a DNS timeout usually means an unset '
        || 'or wrong destination URL in the job that dispatches it.',
        '/jarvis/observability', 'open');
    end if;
  end loop;

  -- Recovery: close anything that no longer meets either detector.
  update public.jarvis_signals
  set status = 'resolved'
  where category = 'edge_failure'
    and status = 'open'
    and not (title = any (v_open_titles));
end;
$$;

revoke all on function public.edge_health_check() from public, anon, authenticated;
grant execute on function public.edge_health_check() to service_role;

-- Hourly, offset to :23 so it does not land on the :00/:15/:30/:45 cron stampede
-- and reads a window that the pg_net worker has had time to resolve.
select cron.schedule('edge-health-check', '23 * * * *', $$ select public.edge_health_check(); $$);
