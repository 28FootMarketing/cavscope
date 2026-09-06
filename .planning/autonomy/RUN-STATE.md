# RUN-STATE — MUSTER autonomy audit

## Run identity
- **Run time (UTC):** 2026-09-06, this session
- **Mode:** AUDIT_AND_PLAN (user did not select AUDIT_PLAN_IMPLEMENT — no production code or config was changed by this audit)
- **Repo:** `28FootMarketing/muster` (GitHub)
- **Branch inspected:** `claude/product-rename-muster-tx5864`, HEAD `b68f8a0`
- **`main` HEAD:** `9ba1512` (merge of PR #18, which includes `b68f8a0` — branch and main are even; no drift)
- **Local working tree:** clean at run start (`git status` empty)
- **Database:** Supabase project `mgtmqucaldkaxvxglguw` ("28 Foot Systems" org, `lagzwoifypecklktafwt`), Postgres 17.6.1.084, region us-east-1, status ACTIVE_HEALTHY
- **Schema under audit:** `muster` (formerly `sentinel`, renamed live via migration `rename_sentinel_schema_to_muster` on 2026-09-03)
- **Deployed edge functions (muster-owned):** `muster-scan` v2, `muster-agent` v1, `muster-ghl-webhook` v4 — all `ACTIVE`
- **Access used:** GitHub MCP (read/write on this repo only), Supabase MCP (full project access — this project is **shared** across ~30+ unrelated 28FS products; every query below was scoped to `muster.*` / `public.muster_*` objects only), local filesystem read of the working tree.

## Scope actually covered in this pass
This is a first evidence-gathering + planning pass, not the full 13-part program. What was completed:
- Repo inventory: all top-level files, `docs/BACKEND.md`, `middleware.js`, all 11 local migration files, all 3 edge functions read in full.
- Live-vs-repo reconciliation: compared `list_migrations` (deployed) against `supabase/migrations/*.sql` (checked in) — found deployed objects with no matching repo file (see EVIDENCE-REGISTER FIND-003, FIND-004).
- Live cron registry (`cron.job`) for `%muster%` jobs, with full `command` text.
- Live function bodies for `muster.autotriage()` (undocumented) pulled via `pg_get_functiondef`.
- `muster.commercial_pricing` live data (stripe_price_id population check).
- Security advisories filtered to `muster`-schema/`muster_*`-function hits only (2 INFO, 36 WARN, 0 ERROR — all WARNs are the intentional anon-executable signup RPCs already accepted as by-design this session).
- Extension inventory (confirmed `vector` 0.8.0 and `pg_cron` 1.6.4 installed platform-wide).
- Sign-in/sign-up code path in `app.html` (confirmed real self-serve signup exists, contradicting an initial hypothesis).

## Explicitly NOT covered in this pass (carried forward, not silently dropped)
- Full read of `muster-scan/index.ts` (31 rules) rule-by-rule correctness — only structure/wiring confirmed, not scan-logic correctness.
- Live pg_net round-trip test of any RPC in this pass (prior session segments did this for GHL; not repeated here).
- Full `get_advisors` **performance** category (only `security` was pulled).
- Storage bucket inventory / backup-restore drill evidence.
- Legal/jurisdiction requirements matrix beyond noting that `muster.jurisdictions`/`jurisdiction_laws` is a *product feature* (advises tenants on their obligations), which is a different thing from 28FS's own operational compliance obligations as a vendor processing tenant data — these must not be conflated (see SAFETY-AND-APPLICABILITY.md).
- Adversarial/negative test suite execution (section 12 of the assignment) — no test harness exists to run one against; building it is itself PRD-004 below.
- Full DATA-INTELLIGENCE-ARCHITECTURE and SAFETY-AND-APPLICABILITY documents are scoped/started, not exhaustively completed to the assignment's full depth — see those files for what's covered vs. deferred and why.

## Continuation pointer
Next executable step if this work resumes: open `.planning/autonomy/BLOCKERS-AND-DECISIONS.md` — item B-1 (GHL vs. Stripe checkout) blocks PRD-002/003 and should be resolved by Anthony before any further checkout automation work is built, or it will be built twice again.
