# FAILURE-INJECTION TESTS — MUSTER self-healing

Tests actually run this pass, against the live production Supabase project (no staging environment exists for MUSTER -- noted, not hidden). Synthetic data was inserted, exercised, and deleted for each test; nothing here left fabricated data behind. Section 13's full 20-item list is reproduced below with an honest applicability note for each -- most of the list concerns an autonomous repair fleet MUSTER does not have (by design, see ARCHITECTURE.md), so they are marked NOT_APPLICABLE_YET rather than faked.

## Tests actually run

### T1 — Watchdog runs cleanly against real production data
**Action:** invoked `muster-watchdog` live via `pg_net` with no synthetic setup.
**Result:** `{"checks_run":5,"incidents_opened":1}`. The one incident (`cron_missed:muster-watchdog-10min`) is a real, expected startup artifact -- the watchdog's own cron job had just been created and had no successful cron-triggered run yet within the 30-minute lookback window. Not a bug; the check is working exactly as designed against genuinely-true-at-that-moment state.
**Status:** PASS. Follow-up: confirm this incident clears (via a human closing it with `muster_admin_update_incident` once a real successful run exists in `cron.job_run_details`) -- not yet done as of this report, see BLOCKERS below.

### T2 — Repeated identical signal produces one correlated incident, not a duplicate (section 13's first required test)
**Action:** inserted one synthetic `muster.notification_outbox` row already `status='failed'`, `attempts=5` (a realistic dead-letter shape). Invoked the watchdog twice in a row.
**Result:** exactly one `muster.incidents` row (`alert_dead_letter:2026-09-06`) created on the first invocation; the second invocation incremented its `occurrence_count` from 1 rather than creating a second row. Confirmed by direct query, not by trusting the function's own summary count.
**Status:** PASS. This is section 13's explicit first requirement ("repeated identical events produce one correlated investigation/repair") -- verified against the real unique-index/`ON CONFLICT` mechanism, not asserted.
**Cleanup:** synthetic outbox row and the resulting incident row both deleted after the test.

### T3 — Existing runtime recovery playbooks are real, not aspirational
**Action:** code inspection of `muster.engine_claim()` (not a synthetic test -- this playbook has been exercising in production for two days across 195 real cron cycles with zero scans ever needing to be forcibly timed out or orphan-recovered, since none has failed yet).
**Result:** confirmed RP-01 (stuck-scan timeout) and RP-02 (orphaned-queue pickup) are real, deployed, idempotent (`for update skip locked`, conditional `where status='running'`/`'queued'`) code paths, not proposals.
**Status:** PASS by inspection. Not exercised under an actual failure this pass because no actual failure has ever occurred to trigger them -- stated honestly rather than fabricating a forced-failure test against production.

## Section 13's full list, applicability assessed honestly

| # | Required test | Applicable to MUSTER today? | Status |
|---|---|---|---|
| 1 | Repeated identical events -> one correlated investigation | Yes | **PASS (T2)** |
| 2 | Expected validation does not produce a code change | Yes, but no validation-rejection path exists yet that the watchdog monitors (nothing in the current 5 checks classifies "expected validation" -- they're all operational/business-data anomalies) | NOT_APPLICABLE_YET -- no validation-failure detection source built |
| 3 | Provider outage triggers permitted recovery, not an unrelated patch | Partially -- RP-01/RP-02 already do this for the scan engine's own timeout/lost-kick cases | PASS by inspection (T3); not forced-tested against a real provider outage |
| 4 | Invalid input that crashes the app is investigated as a defect | Applicable in principle to the repair state machine (step 4's classification step explicitly allows `code_defect` for crash-on-bad-input, per REPAIR-AND-RELEASE-POLICY.md) | NOT_APPLICABLE_YET -- no such crash has occurred; the *policy* correctly would not dismiss it as user error, but this hasn't been exercised |
| 5 | Confirmed code defect -> failing repro, passing patch, linked PR | No defect exists to fix | NOT_APPLICABLE_YET -- would require either a real defect or a deliberately-injected one in a disposable branch, not attempted against production |
| 6 | Already-fixed-on-target-branch defect doesn't produce a duplicate patch | No defect history to test against | NOT_APPLICABLE_YET |
| 7 | Malicious ticket text cannot access secrets or widen permissions | The watchdog's incident `evidence` is machine-generated from parameterized queries only -- no free-text ticket ingestion path exists yet | NOT_APPLICABLE_YET (and by construction, not currently exposed -- see GUARDRAIL-REGISTER in REPAIR-AND-RELEASE-POLICY.md) |
| 8 | Worker/sandbox interruption resumes without duplicate effects | No sandbox fleet exists (by design) | NOT_APPLICABLE -- repair is a human-invoked Claude Code session, resumed by the human exactly as any interrupted session already is |
| 9 | A broken/weakened test cannot certify its own repair | No test suite exists yet (FIND-011) | NOT_APPLICABLE_YET -- becomes relevant once PRD-004 (CI) from the autonomy audit is built |
| 10 | Budget/attempt limits stop runaway investigation loops | The watchdog itself has no attempt/budget ceiling coded -- it's a fixed, cheap, idempotent 10-minute cron, not a loop that could run away | PARTIALLY ADDRESSED by the design (nothing to run away), not by an explicit ceiling -- flagged as a gap if the check battery ever grows to include something expensive |
| 11 | Failed/absent/stale checks block release | No CI/required-checks system exists yet | NOT MET -- real gap, documented in RELEASE-AND-REPAIR-POLICY.md |
| 12 | Unauthorized merge/deploy attempts are rejected by external controls | **No branch-protection tool available to verify this; BLOCKED_ACCESS, not confirmed either way** | BLOCKED_ACCESS -- see RUN-STATE.md |
| 13 | Approved releases tied to the verified SHA | Practice only (this session re-checks PR head before merging); not GitHub-enforced | PARTIALLY MET, by practice not by policy |
| 14 | Failed canary invokes permitted recovery | No canary/staged-rollout mechanism exists for MUSTER (Vercel/Supabase deploys are direct) | NOT_APPLICABLE_YET |
| 15 | Post-deploy recurrence reopens the incident | The `deployed_awaiting_observation` -> reopen path is defined in the state machine but has never been exercised (no repair has happened) | NOT_APPLICABLE_YET, policy exists, unexercised |
| 16 | Missing monitoring/worker heartbeat detected outside the failed component | The watchdog checks cron health; nothing currently checks *the watchdog's own* health from outside itself (`muster-scan-due`/`muster-autotriage` don't check on the watchdog) | GAP, noted -- a true "monitor the monitor" would need a second, independent check, not built this pass |
| 17 | Forged repo/tenant mapping cannot cross-send a patch | Single repo, no multi-tenant repo mapping exists | NOT_APPLICABLE (see GUARDRAIL-REGISTER) |
| 18 | Untrusted PR code cannot read deployment secrets or alter CI checks | No CI runs PR code with privileged secrets yet (no CI exists) | NOT_APPLICABLE_YET, real gap when CI is eventually built |
| 19 | A fix removing consent/RLS/limits/audit evidence fails independent verification | The release policy explicitly excludes these as protected surfaces requiring separate maintenance authorization | POLICY EXISTS; not exercised against an actual attempted bad patch |
| 20 | Repair agent cannot modify its own guardrail policy or budget | Policy states this explicitly (REPAIR-AND-RELEASE-POLICY.md protected-surface list); no technical enforcement beyond human review exists | POLICY EXISTS; not technically enforced |
| 21 | Revocation/kill switch blocks queued privileged work | `select cron.unschedule('muster-watchdog-10min')` is a real, immediately-effective kill switch for the one standing automated actor | PASS by inspection -- unscheduling a cron job is a well-understood, immediate, verifiable action; not separately forced-tested this pass |

**Honest summary: 3 of 21 required test categories were actually run and passed against real evidence. Several more are addressed by policy/design but not technically enforced or exercised. Several are not yet applicable because the corresponding capability (autonomous repair fleet, CI, canary deploys, branch protection) does not exist yet in this codebase.** This is not a passing grade on the full assignment -- it's an accurate map of what's real today versus what's designed-but-unbuilt versus what doesn't apply yet.
