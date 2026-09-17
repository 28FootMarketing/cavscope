-- The control register broke at 2026-09-16 19:23 and nothing noticed for an hour.
--
-- muster_045 swallows a sync_controls failure into an activity_events row so a
-- summary table cannot cost a scan its findings. That is the right trade, but it
-- made the failure invisible: the only trace was one activity row nobody reads.
-- A swallowed error needs a watcher, or it is just a silent error.
--
-- This adds the counter the watchdog needs. muster-watchdog opens a
-- control_register_failure incident when it is non-zero and closes it, via
-- muster_engine_close_cleared_incidents, when it returns to zero.

alter table muster.incidents drop constraint if exists incidents_source_check;
alter table muster.incidents add constraint incidents_source_check
  check (source in (
    'cron_failure', 'cron_missed', 'scan_stuck', 'scan_silent_failure',
    'alert_dead_letter', 'commercial_grant_stuck', 'engine_error_spike',
    'control_register_failure', 'manual'
  ));

create or replace function public.muster_engine_watchdog_summary()
returns jsonb
language sql
security definer
set search_path to ''
as $function$
  select jsonb_build_object(
    'silent_scans', (
      select coalesce(jsonb_agg(jsonb_build_object('scan_id', s.id, 'website_id', s.website_id, 'url', w.url)), '[]'::jsonb)
      from muster.scans s
      join muster.websites w on w.id = s.website_id
      where s.status = 'complete'
        and s.finished_at > now() - interval '20 minutes'
        and (select count(*) from muster.scan_evidence e where e.scan_id = s.id) > 0
        and (select count(*) from muster.findings f where f.last_seen_scan_id = s.id) = 0
        and exists (select 1 from muster.findings f2 where f2.website_id = w.id and f2.last_seen_scan_id <> s.id)
    ),
    'stuck_grants', (
      select coalesce(jsonb_agg(jsonb_build_object('id', g.id, 'email', g.email, 'created_at', g.created_at)), '[]'::jsonb)
      from muster.pending_commercial_grants g
      where g.applied_at is null and g.created_at < now() - interval '48 hours'
    ),
    'dead_letter_alerts', (select count(*) from muster.notification_outbox where status = 'failed' and attempts >= 5),
    'failed_scans_24h', (select count(*) from muster.scans where status = 'failed' and finished_at > now() - interval '24 hours'),
    -- New. muster_045 writes exactly this action string when sync_controls throws.
    'control_register_failures_24h', (
      select count(*) from muster.activity_events
      where action = 'Control register refresh failed'
        and created_at > now() - interval '24 hours'
    )
  );
$function$;

revoke execute on function public.muster_engine_watchdog_summary() from anon, authenticated;

do $$
declare v jsonb;
begin
  select public.muster_engine_watchdog_summary() into v;
  if not (v ? 'control_register_failures_24h') then
    raise exception 'watchdog summary is missing control_register_failures_24h';
  end if;
end $$;