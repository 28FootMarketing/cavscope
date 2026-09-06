# ARCHITECTURE — MUSTER self-healing

## Execution architecture decision (section 6)

**Decision: reuse existing infrastructure end to end. No new sandbox, no new orchestrator platform.**

| Role | Chosen implementation | Why |
|---|---|---|
| Orchestrator (detect, classify, queue) | Supabase Postgres + `pg_cron` + a new Edge Function (`muster-watchdog`) | Identical to every other piece of MUSTER's automation (`muster-scan`, `muster-agent`, `muster-alert-dispatch`) -- same deploy path, same secret-management pattern, same operational team already running it. |
| Durable state | `muster.incidents` table (new) | Same RLS/grant pattern as every other `muster.*` table this session has built. No new database, no new access model to secure. |
| Code-execution / "coding agent" sandbox | **Claude Code Remote sessions** (`mcp__Claude_Code_Remote__create_session`), invoked by a human | Already exists, already does exactly this: checks out the real repo, runs its real toolchain, holds repo-scoped credentials, produces a PR. Building a second, parallel ephemeral-container runtime (Cloudflare Worker+container, or a Hostinger VPS) for a product with **zero recorded incidents in two days of production** would be speculative infrastructure with no evidence it's needed. Revisit only if incident volume or the nature of failures (e.g., needing to run a headless browser, or true 24/7 unattended response with no human available to say "handle incident #N") demands something Claude Code Remote can't do. |
| Escalation trigger | Email (Resend, reusing PRD-001's outbox/dispatch machinery) to the platform owner | Confirmed available. Telegram/CORA is part of the broader 28FS stack but no Telegram tool is connected in this session -- not assumed, checked. Recommendation: point this at Telegram/CORA once that connector is available in a session that has it; email is the honest v1. |
| Release | Human-approved PR merge, unchanged | This is the one piece of "self-healing" infrastructure that must stay a bottleneck by design, not an oversight. See RELEASE-AND-REPAIR-POLICY.md. |

**What this deliberately does NOT build:** an always-on autonomous loop that detects a failure, spins up an isolated sandbox, writes a patch, and opens a PR with zero human awareness in between. That is buildable in principle on top of what exists (a webhook receiver could, given the right credentials, call out to create a Claude Code Remote session automatically) -- but nothing in this codebase's actual failure history justifies that cost and blast-radius increase yet, and the assignment's own instruction ("Do not build a bot that changes code whenever Sentry fires") argues directly against reflexively building maximum automation ahead of need. The chosen design still gets a human out of the *detection* and *evidence-gathering* loop entirely (that part runs unattended, every 10 minutes, forever) -- it only keeps a human in the loop at "should a coding session start," which is also exactly where the release gate already requires a human regardless.

## A. Incident data model

```sql
create table muster.incidents (
  id bigint generated always as identity primary key,
  fingerprint text not null,              -- stable hash of (source, operation, cause candidate) for dedup
  source varchar(40) not null check (source in
    ('cron_failure','cron_missed','scan_stuck','scan_silent_failure','alert_dead_letter',
     'commercial_grant_stuck','engine_error_spike','manual')),
  severity varchar(10) not null check (severity in ('info','warning','critical')),
  status varchar(20) not null default 'open' check (status in
    ('open','investigating','recovered','patch_pending','patch_verified',
     'awaiting_release','deployed_awaiting_observation','closed','wont_fix')),
  affected_operation text not null,        -- e.g. 'muster-scan-due', 'muster.autotriage', 'checkout->onboarding'
  affected_release text,                   -- git SHA or edge function version, when known
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  occurrence_count int not null default 1,
  evidence jsonb not null default '{}'::jsonb,   -- sanitized query results, sample rows, counts -- never raw tenant PII
  root_cause_classification varchar(30) check (root_cause_classification in
    ('expected_validation','user_misunderstanding','ux_defect','permission_denial',
     'expired_connection','bad_configuration','external_outage','quota_limit',
     'data_drift','race_condition','regression','code_defect','security_incident','unresolved')),
  recovery_action varchar(60),             -- which playbook (if any) fired
  recovery_result varchar(20) check (recovery_result in ('recovered','failed','not_applicable')),
  repair_pr_url text,
  closure_evidence jsonb,
  claimed_by text,                          -- session/operator identifier, for single-claim locking
  claimed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Dedup: one open/investigating incident per fingerprint. A repeated identical
-- signal bumps occurrence_count/last_seen_at on the existing row instead of
-- opening a new one -- this is the direct implementation of "do not open a
-- separate repair PR for every repeated exception."
create unique index incidents_fingerprint_active
  on muster.incidents (fingerprint) where status not in ('closed', 'wont_fix');

create index incidents_status on muster.incidents (status) where status not in ('closed', 'wont_fix');

alter table muster.incidents enable row level security;
-- No policies -- deny-by-default, same pattern as every muster_engine_*-backed
-- table this session. Access only through the SECURITY DEFINER RPCs below.
-- This table can contain evidence that would be sensitive if it ever leaked
-- (query results referencing real tenant orgs/emails) -- it is intentionally
-- NOT exposed to any anon/authenticated RPC. Only super-admin and
-- service_role touch it.
```

RPCs (service_role for the watchdog's writes, super-admin for human triage reads):

```sql
create or replace function public.muster_engine_report_incident(
  p_fingerprint text, p_source text, p_severity text, p_affected_operation text,
  p_affected_release text, p_evidence jsonb
) returns bigint
language plpgsql security definer set search_path = '' as $$
declare v_id bigint;
begin
  insert into muster.incidents (fingerprint, source, severity, affected_operation, affected_release, evidence)
  values (p_fingerprint, p_source, p_severity, p_affected_operation, p_affected_release, p_evidence)
  on conflict (fingerprint) where status not in ('closed','wont_fix')
  do update set occurrence_count = muster.incidents.occurrence_count + 1,
    last_seen_at = now(), evidence = excluded.evidence, updated_at = now()
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function public.muster_engine_report_incident(text,text,text,text,text,jsonb) from public, anon, authenticated;
grant execute on function public.muster_engine_report_incident(text,text,text,text,text,jsonb) to service_role;

create or replace function public.muster_admin_incidents(p_status text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if not muster.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(to_jsonb(i) order by i.severity desc, i.last_seen_at desc)
    from muster.incidents i where p_status is null or i.status = p_status), '[]'::jsonb);
end;
$$;
revoke all on function public.muster_admin_incidents(text) from public, anon, authenticated;
grant execute on function public.muster_admin_incidents(text) to authenticated;

create or replace function public.muster_admin_update_incident(p_id bigint, p_status text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if not muster.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  update muster.incidents set status = p_status, updated_at = now(),
    closure_evidence = case when p_note is not null then coalesce(closure_evidence,'{}'::jsonb) || jsonb_build_object('note', p_note, 'at', now()) else closure_evidence end
  where id = p_id;
  return (select to_jsonb(i) from muster.incidents i where i.id = p_id);
end;
$$;
revoke all on function public.muster_admin_update_incident(bigint,text,text) from public, anon, authenticated;
grant execute on function public.muster_admin_update_incident(bigint,text,text) to authenticated;
```

`muster_admin_update_incident` is intentionally `authenticated`-gated behind `is_super_admin()` (same as every other `muster_admin_*` RPC), not `service_role`-only -- a human with super-admin access needs to be able to claim/close incidents from `app.html`, whereas *writing* a new incident is exclusively the watchdog's job.

## B. Recovery playbook registry (section 5)

| ID | Trigger | Precondition | Action | Idempotent? | Blast radius | Status |
|---|---|---|---|---|---|---|
| RP-01 | `muster.engine_claim()`, every call | scan `status='running'` and `started_at` > 10 min ago | mark `failed`, set `error_message` | yes (re-running the update on an already-failed row is a no-op condition-wise) | single scan row | VERIFIED_WORKING (pre-existing, in production) |
| RP-02 | `muster.engine_claim()`, `mode:'due'` calls | scan `status='queued'` and `queued_at` > 2 min ago | claim and run directly, bypassing the lost `pg_net` kick | yes (uses `for update skip locked`, can't double-claim) | single scan row | VERIFIED_WORKING (pre-existing, in production) |
| RP-03 | `muster-alert-dispatch`, every call | outbox row `status='failed'`, `attempts < 5` | requeue to `pending` for the next 5-minute cycle | yes | single outbox row | VERIFIED_WORKING (PRD-001, this session) |
| RP-04 (new) | `muster-watchdog`, every call | `muster.pending_commercial_grants` row unapplied (`applied_at is null`) for > 48 hours | **detect and alert only** -- explicitly NOT auto-recovered. Completing onboarding requires the buyer's own input (org name, website URL); nothing server-side can safely invent that. Correctly HUMAN/CUSTOMER-DEPENDENT, not a gap. | n/a | n/a (read-only detection) | PROPOSED, implemented as an incident source in PRD-001 |
| RP-05 (new) | `muster-watchdog`, every call | a `cron.job_run_details` row for a `muster-*` job with `status <> 'succeeded'` in the last check window, OR a job's most recent run older than `2x` its schedule interval (missed entirely) | **detect and alert only.** No automatic remediation is safe here without knowing *why* the job failed -- retrying blind risks a retry storm on top of whatever's actually broken. | n/a | n/a (read-only detection) | PROPOSED, implemented as an incident source in PRD-001 |
| RP-06 (new) | `muster-watchdog`, every call | a completed scan has `evidence_rows > 0` and `findings_seen = 0` for a website with prior scans that DID produce findings (i.e., a regression to zero, not a first-ever clean scan) | **detect and alert only** (info severity) -- the candidate silent-failure pattern from RUN-STATE.md, turned into a standing check rather than a one-off manual inspection | n/a | n/a (read-only detection) | PROPOSED, implemented as an incident source in PRD-001 |

No new *automatic* recovery action was added beyond documenting RP-01/02/03 (which already existed). RP-04/05/06 are deliberately detection-only: MUSTER's failure surface today (a handful of deterministic cron jobs and a linear scan pipeline) doesn't have a class of failure where blind automatic retry is obviously safe *and* automatic root-cause repair is obviously unsafe to skip -- the honest middle ground for a young product with no incident history is "tell a human fast," not "guess at automated repair for failure modes that have never been observed."

## C. Function / job / cron / webhook registry (additions)

| Name | Trigger | Auth | Reads | Writes | Timeout budget |
|---|---|---|---|---|---|
| `muster-watchdog` (new) | cron, every 10 min | `x-muster-secret` via `muster_engine_secret()`, same pattern as every other engine function | `cron.job_run_details`, `muster.scans`, `muster.notification_outbox`, `muster.pending_commercial_grants`, `muster.findings` | `muster.incidents` via `muster_engine_report_incident` | 30000ms (fixed battery of cheap COUNT/aggregate queries, no external calls) |
| `muster-watchdog-10min` (new cron job) | `*/10 * * * *` | n/a (cron) | -- | -- | 30000ms per `cron_safe_post` call |

## D. Credentials / permission matrix

| Actor | Can read | Can write | Cannot |
|---|---|---|---|
| `muster-watchdog` (service_role) | `cron.job_run_details`, `muster.scans`, `muster.notification_outbox`, `muster.pending_commercial_grants`, `muster.findings` (read-only aggregate queries) | `muster.incidents` (via RPC only) | cannot write to any tenant business table, cannot send an alert directly (that's `muster-alert-dispatch`'s job, reused), cannot touch GitHub |
| Super-admin (`app.html`, `authenticated` + `is_super_admin()`) | all incidents | incident `status`/`closure_evidence` via `muster_admin_update_incident` | cannot bypass `is_super_admin()`, cannot grant itself a broader role |
| A human-invoked Claude Code Remote repair session | the repo (its own checkout), the incident's evidence packet (pasted into its prompt by the human who starts it) | a branch in the repo, a draft PR | **no production database credentials, no Supabase service_role key, no ability to merge its own PR, no ability to edit `.github/`, branch protection, or this `.planning/selfheal/` policy set without a separate explicit maintenance instruction** (section 12A) |
| Anthony (human) | everything | merges PRs, sets Supabase secrets, changes branch protection | -- |

This matrix is the actual implementation of section 2's "no single omnipotent agent" requirement: the watchdog that detects has no code-write or merge capability at all; the repair session that writes code has no production credentials or merge capability; only the human merges.
