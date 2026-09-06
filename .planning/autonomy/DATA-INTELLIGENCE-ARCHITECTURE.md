# DATA-INTELLIGENCE-ARCHITECTURE — MUSTER

MUSTER is a deterministic, typed-SQL system today, by design, not by omission. This document maps the assignment's eight architecture areas to what's actually true, rather than inventing an AI-agent/RAG architecture the product doesn't have and — for its current feature set — doesn't need.

## A. Postgres — VERIFIED_WORKING, this is the real backbone
- Authoritative state lives in `muster.*` tables; `public.muster_*` functions are the only PostgREST-exposed surface (the RPC-shim pattern, used because PostgREST exposes `public`, not `muster`, directly).
- Tenant ownership: every table FKs to `organizations` (directly or via `websites`), enforced by RLS helpers `muster.is_org_member`/`can_write_org`/`is_org_executive` (per docs/BACKEND.md, confirmed by this session's own migration work on `managed_by_org_id`, `commercial_stage`, etc.).
- Privileged workers (`service_role` — the three edge functions plus `pg_cron`) reach the database through `muster_engine_*`-prefixed functions exclusively, explicitly revoked from `anon`/`authenticated` (FIND-005) — this is the correct "privileged worker bypasses ordinary RLS through a controlled door" pattern, not an open service-role key handed to a client.
- Money: not applicable directly — MUSTER holds no ledger; billing lives outside this schema (see SAFETY-AND-APPLICABILITY.md). If PRD-003 (checkout automation) is ever built, whichever path is chosen must NOT introduce a mutable balance column as its own authority — reuse Stripe's/GHL's own record as the source of truth and treat anything in `muster.organizations` as a cached projection of it, reconciled (see section F below), not an independent ledger.
- Full normal-tables-plus-append-only-events pattern: `muster.activity_events` already serves as the append-only event log for every state change this session inspected (org creation, risk auto-open/auto-mitigate, plan changes). It is not versioned or schema'd as a formal outbox today — PRD-001's `notification_outbox` is the first purpose-built outbox table in this schema, and is intentionally modeled as a narrow, single-purpose table rather than a generalization of `activity_events`, because `activity_events` has no delivery-status lifecycle (`pending`/`sending`/`sent`/`failed`) and retrofitting one onto a table already used for audit history would conflate two different concerns.

## B. pgvector and knowledge ingestion — NOT_APPLICABLE_WITH_EVIDENCE today
`vector` extension 0.8.0 is installed platform-wide (FIND-012) but unused by any `muster.*` object. `docs/BACKEND.md` explicitly defers this to "Phase 3, once corpus exists." Correct call: MUSTER's current corpus (scan evidence, jurisdiction laws) is small, structured, and queried by known keys (website_id, rule_id, jurisdiction_code) — there is no unstructured-semantic-search problem yet that SQL doesn't already solve. When Phase 3 does arrive (cross-scan semantic retrieval over `scan_evidence.excerpt`/`sitreps.content_md`, per the roadmap), the minimization concern flagged in SAFETY-AND-APPLICABILITY.md (redact before embedding) must be designed in from the first migration, not added after.

## C. Retrieval and RAG — NOT_APPLICABLE_WITH_EVIDENCE today
100% of MUSTER's retrieval is typed SQL through named RPCs (`muster_findings`, `muster_scans`, `muster_sitrep`, etc.) or the `muster-agent` MCP gateway's typed tools. There is no similarity-search-based routing to override, and therefore no risk of a hard applicability rule being outranked by a similarity score — a real strength of staying deterministic here, worth preserving deliberately rather than "upgrading" to RAG for its own sake later.

## D. Grounding — VERIFIED_WORKING, already a genuine strength
This is the one AI/data-architecture area MUSTER already does well and should be highlighted, not just audited for gaps: `muster.generate_sitrep()` produces SITREPs where "every claim carries `finding_ids` and `evidence_ids`" and markdown renders `[F<id>][E<id>]` (docs/BACKEND.md, and consistent with this session's earlier work on the SITREP viewer pages). This is deterministic-code-computed grounding, not LLM-asserted grounding — a citation that always resolves to a real row, not a similarity score presented as a citation. If Phase 2's `ai_narrative` flag is ever turned on (a model writing SITREP prose), the existing constraint — "citations are validated before save" per the roadmap note — is the right design and should not be weakened to ship narrative faster.

## E. Memory and learning — NOT_APPLICABLE_WITH_EVIDENCE today
No learning system exists. `muster.autotriage()` (FIND-007) is deterministic rule-based automation (severity-scaled due dates, fixed promotion logic), not a system that adapts from outcomes — it does the same thing every time given the same input, which is the correct property for a compliance-risk-triage function; a "learned" version of this logic would need to justify itself against a much higher bar (the assignment's own holdout/regression requirements) before replacing deterministic rules a tenant can audit and trust.

## F. Reconciliation — the section with the most real, actionable gaps
Material pairs that can disagree, found in this specific product:
1. **Live website state vs. findings.** Handled: rescan reconciliation (auto-resolve/reopen) exists and is verified for HTTP-based rules (WORKFLOW-COVERAGE T-06).
2. **GHL deal pipeline stage vs. `muster.organizations.plan`.** Not handled — WORKFLOW-COVERAGE P-04, MISSING_CONFIRMED. No job compares "deal marked Closed Won in GHL" against "org actually provisioned/upgraded in MUSTER." A rep-side mistake (forgetting to trigger the webhook, or the webhook failing silently) has no detector.
3. **Repo migrations vs. deployed schema.** Not handled — and this audit found live drift (FIND-003, FIND-004), not a hypothetical. PRD-002 addresses closing the gap that already exists; nothing currently prevents it from recurring (no CI check that a new `apply_migration` call always has a matching committed file — folds into PRD-004's scope).
4. **`commercial_pricing.stripe_price_id` vs. real Stripe price objects.** Currently in permanent disagreement (all null) because the Stripe path was never finished (FIND-004) — this "pair" doesn't reconcile so much as sit inert, which is itself the signal that the path is dead, not paused.
5. **`notification_outbox` (proposed, PRD-001) vs. Resend's actual delivery outcome.** Not built yet — v1 as specified only tracks send-attempt success/failure from Resend's API response, not open/bounce/complaint webhooks. That's an accepted v1 gap, not silently ignored: a future PRD would add a Resend webhook receiver to close this loop if delivery-rate visibility becomes a real need.

## G. Edge functions and workers
| Function | Trigger | Auth | Timeout budget observed | Notes |
|---|---|---|---|---|
| `muster-scan` | `cron_safe_post` (cron) or direct pg_net call (`muster.do_request_scan`) | `verify_jwt: true` + `x-muster-secret` | 150000ms per `cron_safe_post` call (from the live `cron.job` command text) | 31 HTTP-based rules per docs/BACKEND.md; rule-level correctness not audited this pass |
| `muster-agent` | on-demand, MCP/REST client call | `verify_jwt: false`, `x-muster-api-key` | not observed (on-demand, no cron budget to read) | gateway; cross-tenant denial PRESENT_UNVERIFIED (see SAFETY doc) |
| `muster-ghl-webhook` | GHL workflow's outbound webhook action (human-triggered) | `verify_jwt: false`, `x-muster-secret` | not cron-scheduled, no timeout budget applicable the same way | human dependency, FIND-010 |
| `muster-alert-dispatch` (PROPOSED, PRD-001) | cron, every 5 min | `x-muster-secret`, reusing the existing pattern | 30000ms proposed | blocked on B-2 for the Resend leg only |

## H. Cron and durable execution
| Job | Schedule | Verified active | Notes |
|---|---|---|---|
| `muster-scan-due` | `*/15 * * * *` | yes (`cron.job` row, jobid 134) | catches queued scans older than 2 minutes whose kick was lost, per docs/BACKEND.md — a real misfire-recovery behavior, verified by documentation + live registration, not independently load-tested this pass |
| `muster-autotriage-15min` | `7,22,37,52 * * * *` (offset from `:00` — avoids stampeding at the same tick as `muster-scan-due`, which is a good existing practice worth preserving in any new job) | yes (jobid 138) | undocumented until this audit (FIND-007) |
| `muster-alert-dispatch-5min` (PROPOSED) | `*/5 * * * *` | not yet created | PRD-001 Task 5 |

**Not verified this pass:** retry/backoff/dead-letter specifics inside `muster.engine_claim`/`muster.engine_fail` (the scan-claiming functions) — their names strongly suggest a claim/fail lifecycle exists, but their bodies were not pulled and inspected in this pass. Flagged as PRESENT_UNVERIFIED rather than assumed correct, since PRD-001's own claim function (Task 4) is explicitly modeled after this existing pattern and its correctness matters for both.
