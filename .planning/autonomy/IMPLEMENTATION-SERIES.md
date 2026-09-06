# IMPLEMENTATION-SERIES — MUSTER

## Dependency graph

```
PRD-001 (critical-finding alerts)         -- IMPLEMENTED, live (2026-09-08)
PRD-002 (retroactive migration files)     -- IMPLEMENTED (2026-09-08)
PRD-004 (minimal CI)                      -- independent, ready now
PRD-003 (finish chosen checkout path)     -- IMPLEMENTED (2026-09-08); one manual step outstanding, see below
PRD-005 (GHL<->MUSTER plan reconciliation)-- still open; now scoped to GHL-side only (Stripe side is self-reconciling via the grant table)
PRD-006 (tenant offboarding)              -- BLOCKED on B-3 (retention policy)
PRD-007 (support ticketing wiring)        -- BLOCKED on B-4 (ownership decision)
```

No two of these touch the same schema object or the same edge function, so none of the "ready now" items need to be sequenced relative to each other — they can ship in any order or in parallel. PRD-001 and PRD-002 both touch `muster.autotriage()` conceptually (PRD-002 documents the version that exists today; PRD-001 changes it) — if both are implemented, apply PRD-002's documentation-only migration file first (so the retroactive record matches the pre-PRD-001 state), then PRD-001's change second.

## PRD-001 — Outbound tenant alerts on newly-opened critical/high risks
Fully specified: `prds/PRD-001-critical-finding-alerts.md`. Status: ready to implement pending B-2 sign-off on the email channel (Task 4 only — Tasks 1/2/3/5/6/7 are unconditional).

## PRD-002 — Retroactive migration files for undocumented deployed schema (not yet written in full)
**Scope:** Two `if not exists`/`if exists`-guarded migration files that reproduce, without re-executing anything destructive, what's already live:
1. `add_ai_governance_category` (FIND-003) — the two `ALTER TABLE ... DROP/ADD CONSTRAINT` statements, verbatim, guarded so re-applying to a database that already has the constraint is a no-op (check `pg_constraint` before drop/add, or simply accept `create or replace`-style idempotent DDL since Postgres constraint drop/add isn't naturally idempotent — use `do $$ begin ... exception when undefined_object then null; end $$` guards).
2. `muster_onboarding_pipeline` (FIND-004) — write the file as-is for historical accuracy, but add a prominent header comment flagging it as **currently dead code pending B-1**, so a future reader doesn't assume it's the live checkout path.
Also add a `docs/BACKEND.md` update: document `muster.autotriage()` and `muster-autotriage-15min` (FIND-007) in the phase-1 table and the cron section, since that's real, working, and currently invisible to anyone reading only the docs.
**Why not detailed to PRD-001's depth here:** it's transcription of already-known SQL, not new design — the risk is low and the work is mechanical. Flagging it as a real task rather than skipping it, per the assignment's "every gap maps to a task" rule.
**Acceptance test:** `git diff` against a fresh `supabase db reset`-style replay (or, since there's no local Supabase CLI stack confirmed in this repo, a manual statement-by-statement comparison) shows zero drift between repo and live schema for these two migrations.

## PRD-003 — Finish the chosen checkout path (BLOCKED on B-1)
Not detailed until B-1 is answered — writing SQL/edge-function detail now would mean building one of the two paths (GHL's `muster_ghl_provision` extension work, or Stripe's `muster-stripe-webhook` + price-ID backfill) and then likely rebuilding it once the real answer is known.

## PRD-004 — Minimal CI (not yet written in full)
**Scope:** A single GitHub Actions workflow, `.github/workflows/check.yml`, that on every PR: extracts and `node --check`s every `<script>` block in `*.html` (the exact manual step this session already performs by hand each time), and — if a Supabase MCP-equivalent CLI credential is available in CI, which is not yet established — runs a security-advisor-style lint. If no such credential is available, scope this PRD down to just the `node --check` step and flag the advisor-in-CI half as BLOCKED_ACCESS pending a decision on whether to give CI its own scoped Supabase credential (a real security tradeoff worth Anthony's explicit sign-off, not a default to make silently).
**Why this matters:** every "verified" claim in this entire audit is a snapshot (FIND-011). This is the cheapest available step toward making at least one class of regression (a JS syntax error shipped to a static HTML page) impossible to merge silently.

## PRD-005 — GHL pipeline state <-> MUSTER org plan reconciliation (BLOCKED on B-1)
Addresses WORKFLOW-COVERAGE P-04. Not detailed — the reconciliation source of truth depends entirely on which checkout path B-1 keeps.

## PRD-006 — Tenant offboarding / cancellation (BLOCKED on B-3)
Addresses T-16/T-17. Not detailed — needs a retention-policy answer first (how long scan evidence/findings/SITREPs survive a cancellation), which is a business/compliance decision, not an engineering one.

## PRD-007 — Support ticketing wiring (BLOCKED on B-4)
Addresses P-08. Not detailed — needs an ownership decision (reuse the existing separate `isupport` product in the same Supabase project vs. GHL vs. nothing yet).

## Deployment order recommendation
1. PRD-002 first (pure documentation/reproducibility fix, zero behavior change, de-risks everything after it by making the repo trustworthy again).
2. PRD-001 Tasks 1/2/3/5/6/7 (schema + trigger + cron + admin visibility — safe, additive, no external dependency).
3. Resolve B-2 (Resend key + domain) in parallel with the above — not a blocker for 1-2.
4. PRD-001 Task 4 (actual email dispatch) the moment B-2 is answered.
5. Resolve B-1 — then PRD-003 and PRD-005 become writable.
6. PRD-004 (CI) can slot in anywhere; recommended right after PRD-002 so it starts protecting the repo as early as possible.
