# EVIDENCE-REGISTER — MUSTER

Statuses used: VERIFIED_WORKING, PRESENT_UNVERIFIED, PARTIAL, MISSING_CONFIRMED, BROKEN, BLOCKED_ACCESS, HUMAN_DEPENDENT, PROPOSED, NOT_APPLICABLE_WITH_EVIDENCE.

---

### FIND-001 — Shared multi-tenant-brand database, not a MUSTER-dedicated project
- **Status:** VERIFIED_WORKING (as an architectural fact; not a defect by itself)
- **Evidence:** `mcp__Supabase__list_migrations` on project `mgtmqucaldkaxvxglguw` returns 400+ migrations spanning unrelated products: RIOS, CORA, GOVRNR, BRD, GFFH, FlagIntel, BotForge, Iron, CAW, LMS, isupport, ledgerwise, ROS, Steward, etc. `muster` is one schema among many in one shared Postgres instance, consistent with CLAUDE.md's "shared Supabase project" and the user profile's stated Supabase ref.
- **Impact:** Any project-wide security/performance advisory, extension change, `vault` secret naming collision, or `cron.job` capacity limit is a cross-product concern. MUSTER's own security posture (RLS, grants) must not assume schema isolation is the only protection — `search_path` hardening, explicit schema-qualification, and the `public.muster_*` shim pattern already in use are the correct compensating controls and were verified present (see FIND-005).
- **Action implied:** none required now; documented so future audits don't mistake "clean project-wide advisor run" for "clean MUSTER run" — they must always be filtered.

### FIND-002 — Repo migration filenames do not match the deployed migration version registry
- **Status:** VERIFIED_WORKING (traceability quirk, not a functional bug)
- **Evidence:** Local file `supabase/migrations/20260907180000_muster_pricing_stage_toggle.sql` (filename timestamp 2026-09-07T18:00:00) corresponds to deployed `version: "20260906024916"` name `muster_pricing_stage_toggle` (2026-09-06T02:49:16) per `list_migrations`. This offset is consistent across every muster migration checked — the deployed version id is assigned by the apply tool at apply time, not derived from the filename.
- **Impact:** Anyone reasoning about "what ran when" from filenames alone will be wrong by about a day. Low severity today; becomes a real problem the first time someone needs to bisect a production incident by migration order.
- **Action implied:** PRD candidate, low priority: adopt the deployed version id as the filename prefix at write time, or document the offset in `docs/BACKEND.md`.

### FIND-003 — Deployed migration `add_ai_governance_category` has no matching file in the repo
- **Status:** MISSING_CONFIRMED (repo does not reproduce production schema)
- **Evidence:** `supabase_migrations.schema_migrations` version `20260906005205` name `add_ai_governance_category` contains: `ALTER TABLE muster.jurisdiction_laws DROP CONSTRAINT ... ADD CONSTRAINT ... CHECK (category = ANY (... 'ai_governance'))` and the equivalent for `muster.scan_rules`. No file in `supabase/migrations/` produces this statement.
- **Impact:** Low risk on its own (additive check-constraint value), but it means the repo cannot be replayed from empty to reproduce the live schema. Anyone bootstrapping a new environment from `git clone` + migrations would get a schema that rejects `category = 'ai_governance'` rows that the live database already has.
- **Action implied:** Write the missing migration file retroactively (`supabase/migrations/<ts>_add_ai_governance_category.sql`, no-op on already-applied databases via `if exists`/`if not exists` guards) so the repo is reproducible again.

### FIND-004 — Deployed migration `muster_onboarding_pipeline` (Stripe self-serve checkout) has no matching file in the repo and is materially significant
- **Status:** MISSING_CONFIRMED + BROKEN (deployed but non-functional)
- **Evidence:**
  - `supabase_migrations.schema_migrations` version `20260906012143` name `muster_onboarding_pipeline` adds `muster.commercial_pricing.maps_to_plan`, a unique index on `stripe_price_id`, and `muster.onboard_client(p_auth_user_id, p_email, p_name, p_org_name, p_stripe_price_id, p_website_name, p_website_url, p_included_client_orgs)` — a `SECURITY DEFINER` RPC whose own comment says it is "Called by the Stripe webhook Edge Function AFTER it has created ... the Supabase Auth user."
  - No file in `supabase/migrations/` contains this SQL.
  - `list_edge_functions` on this project shows a generic shared `stripe-webhook` (v61) and several other product-specific ones (`brd-stripe-webhook`, `caw-stripe-webhook`, `ros-stripe-webhook`, `cora-stripe-webhook`, etc.) but **no `muster-stripe-webhook`** and nothing in `muster-scan`/`muster-agent`/`muster-ghl-webhook` calls `muster.onboard_client`.
  - `select tier, stage, stripe_price_id, maps_to_plan from muster.commercial_pricing` returns `stripe_price_id: null` on all 4 rows.
  - `muster.onboard_client` looks up `maps_to_plan` by `stripe_price_id` and does `if v_plan is null then raise exception`. With all `stripe_price_id` null, any call with a real Stripe price id fails; a call with `null` would collide across all 4 tiers/stages.
- **Impact:** This is a second, independent, unfinished checkout-automation path that nobody decided to build in this session and that this session's own GHL work never accounted for. It directly conflicts in intent with `public.muster_ghl_provision` (the GHL sales-assisted path built this session, which is code-complete, git-tracked, and live-tested). Two different, non-interoperating provisioning paths for the same "new paying tenant" event is a real architecture fork, not a duplicate-effort nitpick: if both were finished independently, a prospect could be double-provisioned (one org from GHL, a second from Stripe) with no reconciliation between them.
- **Action implied:** **This is BLOCKER B-1** — see BLOCKERS-AND-DECISIONS.md. Do not build either path further until Anthony decides: (a) Stripe self-serve only, (b) GHL-assisted only (delete the dead Stripe schema), or (c) both, with an explicit rule for which tiers use which path and how they'd reconcile if a contact somehow enters both. Whoever built `muster_onboarding_pipeline` and why is UNKNOWN — not established by any evidence available to this audit; flagging as UNKNOWN rather than guessing.

### FIND-005 — `revoke ... from public` alone does not revoke Supabase's default anon/authenticated grants
- **Status:** VERIFIED_WORKING (as a documented, now-institutionalized fix)
- **Evidence:** `docs/BACKEND.md` and this session's own migrations (`20260907160000_muster_ghl_checkout.sql` comment, lines 36-41) record the discovery, and the live security advisor confirms zero ERROR/unexpected-WARN findings for muster's service-role-only functions today (`muster_ghl_webhook_secret`, `muster_find_auth_user_by_email`, `muster_ghl_provision`, `muster_admin_set_pricing_stage` all correctly restricted). The 36 WARN-level advisories that do mention `muster` are exclusively the intentional anon-executable signup RPCs (`muster_countries`, `muster_regions`, `muster_plans`, `muster_jurisdiction_advisory`, `muster_public_pricing`) — all deliberate per `docs/BACKEND.md`'s own "Anonymous (signup page)" RPC list.
- **Impact:** none negative — recorded here as a positive, verified control, not a gap.

### FIND-006 — `muster.pricing_settings` and `muster.scan_postprocess` have RLS enabled with zero policies (deny-all by table, access only via SECURITY DEFINER RPC)
- **Status:** VERIFIED_WORKING (matches the RPC-shim access pattern used throughout; flagged INFO by the linter, not a defect)
- **Evidence:** advisor detail: `Table muster.pricing_settings has RLS enabled, but no policies exist`; same for `muster.scan_postprocess`.
- **Impact:** None today — both tables are read/written exclusively through `SECURITY DEFINER` functions owned by a role that bypasses RLS, matching every other `muster.*` table's access pattern. Documented explicitly here so a future pass doesn't "fix" this by adding permissive policies that would actually weaken the deny-by-default posture.

### FIND-007 — `muster.autotriage()` + `muster-autotriage-15min` cron job: real, working, undocumented automation
- **Status:** VERIFIED_WORKING, but MISSING_CONFIRMED from documentation and git
- **Evidence:** `cron.job` row `{jobid: 138, jobname: "muster-autotriage-15min", schedule: "7,22,37,52 * * * *", active: true, command: "select muster.autotriage();"}`. Full function body pulled via `pg_get_functiondef('muster.autotriage'::regproc)`: it runs `muster.drift_detect()` on up to 50 newly-completed scans, auto-opens a `muster.risks` row + a `muster.remediation_actions` row (with a severity-scaled due date: 7/30/90 days for critical/high/medium) for every open/reopened finding not yet linked to a risk, and auto-mitigates + verifies risks whose findings later resolve. This is real, running, tenant-facing risk-register automation.
- **Impact (positive):** This closes part of what looked like a gap — findings do not just sit as raw scan output; they are automatically promoted into a tracked risk with an owner and a due date, and automatically closed out on re-scan. This is genuine autonomous execution of a real business workflow (risk triage), not just data collection.
- **Impact (negative):** Not in `docs/BACKEND.md`, not in any git-tracked migration, not mentioned in the RPC surface list. Nobody reading the repo would know this exists. Same drift class as FIND-003/004.
- **Action implied:** Write the missing migration file; add a "Risk auto-triage" row to `docs/BACKEND.md`'s phase-1 table; add `muster-autotriage-15min` to the Cron registry doc.

### FIND-008 — No automated notification path exists for new critical findings or risks
- **Status:** MISSING_CONFIRMED
- **Evidence:** `information_schema.routines` in schema `muster` filtered for `%notify%|%alert%|%telegram%|%email%|%sms%` returns zero rows. `docs/BACKEND.md`'s own "Phase 2 and later (not started)" list includes "Telegram alerts to CORA ... on new critical findings" — the code confirms this claim is accurate, not aspirational-but-secretly-done.
- **Impact:** This is the single largest verified tenant-facing autonomy gap. A tenant's only way to learn that MUSTER found a new critical issue on their site is to open `app.html`/`sitrep.html` and look. There is no push (email, SMS, Telegram) triggered by `muster.autotriage()` opening a critical risk, by a scan completing, or by posture score crossing into the "red" band. Given the product's stated premise — buying confidence that you'll know when something's wrong without watching it yourself — this is a direct hit against the product's own value proposition, not a peripheral nice-to-have.
- **Action implied:** **PRD-001** (this pass includes a fully-specified PRD for this — see `prds/PRD-001-critical-finding-alerts.md`).

### FIND-009 — Self-serve signup and onboarding on `app.html` is real, zero-human-touch (contradicts an initial working hypothesis)
- **Status:** VERIFIED_WORKING (code-level; production Auth dashboard config PRESENT_UNVERIFIED — see caveat)
- **Evidence:** `app.html` lines ~2789-2813: the sign-in modal has three real buttons wired to distinct Supabase Auth calls — `Live.submitAuth(event,'signin')`, `'magic'` → `this.sb.auth.signInWithOtp(...)`, `'signup'` → `this.sb.auth.signUp({email, password, ...})` (lines 5151, 5158) — followed by a "Set up your workspace... no human in the loop" onboarding modal that calls `muster_onboard` (line 5277) and then `muster_my_workspace` (line 5289).
- **Caveat:** `docs/BACKEND.md` itself notes Supabase Auth's Site URL / Redirect URLs "must be set in the dashboard (not scriptable through MCP)" for magic links/email confirmation to land back in the app. This audit has no way to read Supabase Auth dashboard settings via MCP, so whether those URLs are currently correct for `app.muster.28footsystems.com` is **PRESENT_UNVERIFIED**, not confirmed working. If misconfigured, magic-link/signup confirmation emails would land the user on the wrong origin and the "no human in the loop" claim would silently fail for every new signup.
- **Action implied:** A cheap, high-value verification task: from a browser (not this sandbox, which cannot reach the public internet per the CLAUDE.md/session history's confirmed network restriction), do one real signup end-to-end and confirm the confirmation link lands on `app.muster.28footsystems.com`. Not performed in this pass — flagged as BLOCKED_ACCESS (sandboxed network) rather than assumed fine.

### FIND-010 — GHL "Closed Won" is a permanent, by-design human dependency in the only currently-functional paid-conversion path
- **Status:** HUMAN_DEPENDENT (verified by design, not an oversight)
- **Evidence:** `supabase/functions/muster-ghl-webhook/index.ts` fires only when a human sales rep in GHL moves a deal to Closed Won, per this session's own prior build ("GHL checkout wiring, phase 1 (sales-assisted)"). This is the *only* currently-functional path from trial to paid tenant (the Stripe path is dead — FIND-004).
- **Impact:** Every paid MUSTER or MUSTER Partner conversion today requires a human (Anthony or 28FS sales staff) to act inside GHL. This is explicitly scoped as "phase 1" by the code's own comments, so it is not a hidden gap — but it is the platform's single largest human-in-the-loop dependency for revenue, and it has no compensating automatic escalation if a rep forgets to mark a deal won (no reconciliation between GHL pipeline stage and MUSTER org `plan` state was found).
- **Action implied:** Contingent on BLOCKER B-1's resolution — see BLOCKERS-AND-DECISIONS.md.

### FIND-011 — No CI, no test framework, no lockfile
- **Status:** MISSING_CONFIRMED
- **Evidence:** `find .github -type f` → empty. `package.json` declares one dependency (`@vercel/functions`) and no `scripts`, no test runner, no lint config. No `package-lock.json`/`yarn.lock`/`pnpm-lock.yaml` in the repo.
- **Impact:** Every verification performed for MUSTER this session (and presumably prior sessions) has been ad hoc — manual `node --check` on extracted script blocks, one-off Playwright runs against `file://` with mocked network, direct `pg_net`/SQL probes. None of it is a repeatable, regression-protecting check that runs automatically on the next change. This is the structural reason every other "verified" claim in this register is a point-in-time observation, not a standing guarantee — a regression in, say, the pricing-stage RPC grants would not be caught until someone thinks to re-check by hand.
- **Action implied:** PRD candidate (not detailed in this pass): a minimal CI step that at least runs `node --check` on every HTML file's extracted script and a Supabase advisor check on PR, before any claim of "protected" automation is made.

### FIND-012 — pgvector and pg_cron are installed platform-wide; Phase 3 (RAG/semantic search) is not infra-blocked, only not-yet-built
- **Status:** NOT_APPLICABLE_WITH_EVIDENCE (today) / PROPOSED (future)
- **Evidence:** `list_extensions` shows `vector` 0.8.0 installed in schema `public`, `pg_cron` 1.6.4 installed. `docs/BACKEND.md`: "pgvector / RAG / memory — Deferred by design ... phase 3 once corpus exists." No `muster.*` table or column uses `vector` type (not checked exhaustively table-by-table in this pass, but no migration references it).
- **Impact:** None — this is a correct, deliberate product decision, not a gap. Recorded so the DATA-INTELLIGENCE-ARCHITECTURE document doesn't invent a RAG/memory system MUSTER doesn't have and doesn't currently need (its retrieval is 100% typed SQL against `findings`/`scans`/`sitreps`, which is the right choice for a deterministic compliance-evidence product).
