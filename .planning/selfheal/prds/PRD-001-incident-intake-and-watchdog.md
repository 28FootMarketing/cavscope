# PRD-001 — Incident intake table + `muster-watchdog` detection cron

## Header
- **Depends on:** nothing (additive, independent of every other PRD in this repo)
- **Unlocks:** the repair state machine in REPAIR-AND-RELEASE-POLICY.md (nothing to triage without this)
- **Verified reuse:** ~80% -- reuses the `muster_engine_*` SECURITY DEFINER pattern, the `muster_admin_*` super-admin pattern, `muster.is_super_admin()`, `cron_safe_post`, `muster_engine_secret()`, and PRD-001 (tenant alerts)'s outbox/dispatch edge function as the model for `muster-watchdog`'s structure. Net-new: one table, three RPCs, one edge function, one cron job, six detection queries.
- **Atomic task count:** 8
- **Verification loops:** 2 (live invocation against real production data with zero synthetic setup; one synthetic-incident injection test to prove dedup + the super-admin read path)

## Task 1 — `muster.incidents` table + RPCs
Exact SQL: see ARCHITECTURE.md section A, reproduced verbatim in the migration file. No changes here.
**Check:** table exists with the two indexes; `get_advisors security` shows the same "RLS enabled, no policies" INFO pattern as every prior `muster_engine_*`-backed table, no unexpected WARN/ERROR.

## Task 2 — `muster-watchdog` edge function: cron/job-health check (RP-05 source)
```
select jobid, jobname, status, start_time
from cron.job_run_details
where jobid in (select jobid from cron.job where jobname like 'muster-%')
  and start_time > now() - interval '20 minutes'
  and status <> 'succeeded';
```
Also flags a job whose most recent run is older than 2x its own schedule interval (a *missed* run produces no `job_run_details` row at all, so absence has to be checked against `cron.job.schedule`, not just failure status). Fingerprint: `cron_failure:<jobname>:<date>` (one incident per job per day, not one per failed run, to avoid flooding).

## Task 3 — silent scan-completion check (RP-06 source)
```
select s.id, s.website_id, w.url
from muster.scans s
join muster.websites w on w.id = s.website_id
where s.status = 'complete'
  and s.finished_at > now() - interval '20 minutes'
  and (select count(*) from muster.scan_evidence e where e.scan_id = s.id) > 0
  and (select count(*) from muster.findings f where f.last_seen_scan_id = s.id) = 0
  and exists (select 1 from muster.findings f2 where f2.website_id = w.id and f2.last_seen_scan_id <> s.id)
  -- only flags a regression to zero, not a website's first-ever clean scan
```
Severity `info` -- this is a "worth a human glance," not a page-Anthony-at-2am signal.

## Task 4 — commercial-grant-stuck check (RP-04 source)
```
select id, email, plan, stage, created_at
from muster.pending_commercial_grants
where applied_at is null and created_at < now() - interval '48 hours';
```
Severity `warning` -- a real customer paid and never got their account; this is a support/reachout item for Anthony, not a code defect by default (though worth checking whether the invite email actually landed -- that's exactly the investigation step, not something to assume from the incident alone).

## Task 5 — alert dead-letter check
```
select count(*) from muster.notification_outbox where status = 'failed' and attempts >= 5;
```
Severity `warning` if count > 0. (PRD-001's own retry logic already handles transient failures -- this only fires once something has definitively stopped retrying.)

## Task 6 — engine error-rate check
Reuses the exact counts `muster_admin_overview().engine` already exposes (`failed_24h`, `complete_24h`) -- if `failed_24h > 0`, open an incident (today this can only mean the RP-01 timeout path fired, since nothing else sets `status='failed'` yet -- still worth surfacing so a human notices a pattern of timeouts, which RP-01 masks from being a hard error).

## Task 7 — wire all six checks into one `muster-watchdog` edge function, deployed, cron every 10 minutes
Each check that fires calls `public.muster_engine_report_incident(...)` with a stable fingerprint. Function returns a summary JSON (`{checks_run, incidents_opened}`) for its own invocation log.

## Task 8 — surface incidents in `muster_admin_overview()`
Add `'incidents', (select coalesce(jsonb_agg(...), '[]'::jsonb) from muster.incidents where status not in ('closed','wont_fix'))` -- same pattern as the `alerts` field PRD-001 (tenant alerts) already added.

## Acceptance tests (run live, not simulated)
1. Invoke `muster-watchdog` against real production data with zero incidents expected (current state) -- confirm `{checks_run: 6, incidents_opened: 0}` and no error.
2. Insert one synthetic `muster.notification_outbox` row already in a terminal `failed` state with `attempts=5` (mirroring a real dead-letter, not a fabricated schema), re-invoke the watchdog, confirm exactly one `muster.incidents` row opens with `source='alert_dead_letter'`, then invoke a third time and confirm `occurrence_count` increments rather than a second row being created (dedup proof). Clean up both the synthetic outbox row and the incident row afterward.
3. Confirm `muster_admin_incidents()` returns the row while super-admin-gated (call fails as expected for a non-super-admin context, per the existing `is_super_admin()` pattern already proven this session).

## Rollback
```sql
select cron.unschedule('muster-watchdog-10min');
drop function if exists public.muster_admin_update_incident(bigint,text,text);
drop function if exists public.muster_admin_incidents(text);
drop function if exists public.muster_engine_report_incident(text,text,text,text,text,jsonb);
drop table if exists muster.incidents;
```
