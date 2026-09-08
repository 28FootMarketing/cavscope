-- Detector A held signals open on functions that had already recovered.
--
-- Found by using it. The brd-* 401 wave that edge_health_check() flagged as
-- "high, 22 of 56 calls failing" was not an ongoing 39% failure rate at all --
-- it was a bounded incident, 09:28:44 to 14:45:01 on 2026-09-07, that was over
-- five hours before the signal was raised. Every one of those functions has been
-- green since; the last 401 on each precedes its own redeploy by seconds.
--
-- Detector A reads a 24h window, so a finished outage stays inside that window
-- and keeps producing a "failure rate" long after the failing stopped. Those
-- signals would have sat open until 14:45 tomorrow, a 19-hour lag on a resolved
-- incident, and reading "22 of 56 failed in 24h" the whole time -- true as
-- arithmetic, false as a description of the system's state.
--
-- The guard: Detector A now also requires a failure in the last 2 hours. A rate
-- alone says something failed recently-ish; a recent failure says it is still
-- failing. Only the second is worth anyone's attention.
--
-- This does not weaken real detection. publish-due (57 of 57 in 24h, 8 in the
-- last 2h) and coach-enrich-dispatch (8 of 8, 1 in the last 2h) both still fire
-- critical. Detector B is untouched: "no success in 48h" cannot go stale the way
-- a rate can, because a success is exactly what clears it.

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
      -- The "is it still happening" guard. See header.
      count(*) filter (where queued_at > now() - interval '2 hours'  and is_fail)            as fail_2h,
      count(*) filter (where is_fail)                                                        as fail_72h,
      max(queued_at) filter (where is_ok)                                                    as last_success,
      max(queued_at) filter (where is_fail)                                                  as last_failure,
      max(queued_at)                                                                         as last_call,
      max(status_code) filter (where is_fail)                                                as worst_code,
      (array_agg(error_msg order by queued_at desc) filter (where error_msg is not null))[1]  as sample_error
    from inv
    group by fn
    having max(queued_at) > now() - interval '72 hours'
  loop
    continue when v_row.fn = '(non-function url)';

    v_severity := null;

    -- Detector A: failing at a rate that matters, on enough calls to be sure,
    -- AND still failing right now.
    if v_row.calls_24h >= 5
       and v_row.fail_24h * 100 >= v_row.calls_24h * 25
       and v_row.fail_2h > 0 then
      v_severity := case
        when v_row.ok_24h = 0 then 'critical'
        when v_row.fail_24h * 100 >= v_row.calls_24h * 50 then 'high'
        when v_row.fail_24h >= 20 then 'high'
        else 'medium'
      end;
      v_detail := format(
        '%s of %s calls failed in 24h (%s%%), %s in the last 2h. Last success: %s. Worst status: %s.%s',
        v_row.fail_24h, v_row.calls_24h,
        round(100.0 * v_row.fail_24h / nullif(v_row.calls_24h, 0)),
        v_row.fail_2h,
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
        || 'or wrong destination URL in the job that dispatches it. Check whether the failures are a '
        || 'bounded window or ongoing before treating a percentage as a current rate.',
        '/jarvis/observability', 'open');
    end if;
  end loop;

  update public.jarvis_signals
  set status = 'resolved'
  where category = 'edge_failure'
    and status = 'open'
    and not (title = any (v_open_titles));
end;
$$;

revoke all on function public.edge_health_check() from public, anon, authenticated;
grant execute on function public.edge_health_check() to service_role;
