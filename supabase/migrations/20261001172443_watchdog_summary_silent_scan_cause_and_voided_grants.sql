-- Watchdog summary: say WHY a scan looked silent, and stop flagging voided grants.
--
-- Two changes to cavscope_engine_watchdog_summary(), both small and additive.
--
-- 1. silent_scans now carries engine_version and skipped_inactive for each scan.
--    A "silent" scan (evidence collected, zero findings recorded, while the site
--    had findings before) has two very different causes the check cannot tell
--    apart: the engine failed to evaluate its rules, or it emitted findings for
--    rules still held inactive and ingest dropped every one (the staged-activation
--    mechanism in CLAUDE.md). Read on 2026-10-01, 35 of the 39 open
--    scan_silent_failure incidents were the second kind (skipped_inactive > 0 on
--    the scan's own summary). The incident evidence now says which, so triage is a
--    glance and not a query. The old watchdog ignores the extra keys.
--
-- 2. stuck_grants excludes cancelled grants. Migration 20261001011757 voids a grant
--    whose subscription ended before the buyer created an organization by setting
--    cancelled_at, leaving applied_at null. Without this the same grant would be
--    reported as stuck after 48 hours: a deliberate cancellation read as a failure.
--
-- The matching close paths (a source that can open an incident must be able to close
-- it) are in the watchdog edge function, not here.

CREATE OR REPLACE FUNCTION public.cavscope_engine_watchdog_summary()
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select jsonb_build_object(
    'silent_scans', (
      select coalesce(jsonb_agg(jsonb_build_object('scan_id', s.id, 'website_id', s.website_id, 'url', w.url, 'engine_version', s.engine_version, 'skipped_inactive', coalesce((s.summary->>'skipped_inactive')::int, 0))), '[]'::jsonb)
      from cavscope.scans s
      join cavscope.websites w on w.id = s.website_id
      where s.status = 'complete'
        and s.finished_at > now() - interval '20 minutes'
        and (select count(*) from cavscope.scan_evidence e where e.scan_id = s.id) > 0
        and (select count(*) from cavscope.findings f where f.last_seen_scan_id = s.id) = 0
        and exists (select 1 from cavscope.findings f2 where f2.website_id = w.id and f2.last_seen_scan_id <> s.id)
    ),
    'stuck_grants', (
      select coalesce(jsonb_agg(jsonb_build_object('id', g.id, 'email', g.email, 'created_at', g.created_at)), '[]'::jsonb)
      from cavscope.pending_commercial_grants g
      where g.applied_at is null and g.cancelled_at is null and g.created_at < now() - interval '48 hours'
    ),
    'dead_letter_alerts', (select count(*) from cavscope.notification_outbox where status = 'failed' and attempts >= 5),
    'failed_scans_24h', (select count(*) from cavscope.scans where status = 'failed' and finished_at > now() - interval '24 hours'),
    -- New. muster_045 writes exactly this action string when sync_controls throws.
    'control_register_failures_24h', (
      select count(*) from cavscope.activity_events
      where action = 'Control register refresh failed'
        and created_at > now() - interval '24 hours'
    )
  );
$function$;
