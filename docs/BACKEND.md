# MUSTER backend (phase 1)

Product: MUSTER, by 28 Foot Systems. Target host: muster.28footsystems.com.
Data plane: dedicated Supabase project `hjowfnzpomzxazmzywxw` ("Muster"), schema `muster`, plus
`public.muster_*` RPC shims. Orchestration: Supabase Edge Functions + pg_cron. No n8n.

**2026-09-16 project split, unresolved:** MUSTER was originally built on the shared `mgtmqucaldkaxvxglguw`
("28 Foot Systems") project (everything below this note was written against it, including the phase-1
migration filenames). At some point a dedicated `hjowfnzpomzxazmzywxw` project was stood up with the same
starting data (same org ids/names) and has since run independently — it now has its own edge functions
(`muster-scan`, `muster-agent`, `muster-alert-dispatch`, `muster-watchdog`, `muster-embed-docs`,
`muster-verify-site`, `muster-stripe-webhook`, `muster-ghl-webhook`, `muster-resend-webhook`,
`muster-backfill-embeddings`, `muster-auth-smoke`, `muster-set-password` — most with no source in this repo)
and its own active cron jobs, diverging from the shared project's data ever since. `app.html`, `index.html`,
and `sitrep.html` all now point at `hjowfnzpomzxazmzywxw` (confirmed authoritative 2026-09-16). The shared
project's `muster-scan-due-15min` cron job was still active and still scanning as of that date — it has not
been decommissioned. Until it is, the shared project keeps generating its own diverging scans/findings/sitreps
that nothing reads. Decommissioning it (disabling the cron job, and deciding whether to drop the shared
project's `muster.*` schema and edge functions) is a deliberate call for Anthony to make, not something to do
by default — this note exists so nobody assumes the shared project is dead just because the frontend moved on.
This doc, `supabase/migrations/`, and `supabase/config.toml` describe the dedicated project going forward;
treat any remaining `mgtmqucaldkaxvxglguw` reference below as historical unless a section says otherwise.

## What phase 1 delivers

| Partner memo item | Status | Where |
|---|---|---|
| Postgres data model | Done | `muster.*` (16 legacy Sentinel tables kept, 14 new tables) |
| Audit / finding / evidence storage | Done | `scans`, `scan_evidence`, `findings`, `finding_evidence` |
| SITREP generation | Done, deterministic | `muster.generate_sitrep()`; replaces Board Report and Plain English as sections |
| Grounded citations | Done | Every SITREP claim carries `finding_ids` and `evidence_ids`; markdown renders `[F<id>][E<id>]` |
| Reconciliation | Done for HTTP rules | Findings not observed by a completed scan auto-resolve; reappearance reopens |
| Dedupe fingerprint | Done | `sha256(website|rule|normalized_url|location)`, unique per website |
| pgvector / RAG / memory | Deferred by design | Retrieval is SQL; semantic search is phase 3 once corpus exists |
| Self-serve onboarding | Done | `public.muster_onboard(jsonb)` creates org, membership, appetite, brand, website, first scan |
| Jurisdiction advisor | Done | 199 countries, 101 jurisdictions, 46 law rows mapped to scan rules |
| White-label + personalization | Done | `brand_profiles` (org default, per-website override), `user_preferences` |
| Super admin + feature flags | Done | `users.role = super_admin`, `feature_flags`, `feature_flag_overrides`, `muster_admin_*` RPCs |
| Agent / AI-employee ready | Done | `agents`, `api_keys`, `muster-agent` edge function (MCP + REST) |

## Layout

```
supabase/
  config.toml
  migrations/
    20260904120000_muster_phase1_scan_engine.sql        rules, scans, evidence, findings, sitreps, engine, SITREP generator
    20260904120100_muster_onboarding_brand_flags_agents.sql  plans, countries, jurisdictions, laws, brand, prefs, flags, agents, keys, vault secret
    20260904120200_muster_tenancy_rls.sql               membership helpers, grants, RLS on every muster table
    20260904120300_muster_public_rpc.sql                public.muster_* surface (43 functions)
    20260904120400_muster_cron.sql                      muster-scan-due every 15 minutes
  functions/
    muster-scan/index.ts    HTTP-native scanner (31 rules), verify_jwt on, shared secret header
    muster-agent/index.ts   MCP (JSON-RPC 2.0, streamable HTTP) + REST gateway, API-key auth
```

All five migrations are applied to the shared project and both functions are deployed (2026-09-04).

## Access model

- Supabase Auth users hit `public.muster_*` RPCs with their JWT. Membership is enforced in SQL by `muster.is_org_member`, `muster.can_write_org`, `muster.is_org_executive`.
- Every `muster.*` table has RLS for `authenticated`; catalog tables are read-only; scan output tables are read-only for members.
- `super_admin` (set with `public.muster_admin_set_user_role(email, 'super_admin')` by an existing super admin, or the bootstrap SQL below) passes every membership check.
- `service_role` (edge functions, cron) uses `public.muster_engine_*` only. Those functions are revoked from `anon` and `authenticated`.
- Agents authenticate with `x-muster-api-key: mk_...`. Keys are stored as SHA-256 hashes. Scopes: `read`, `scan`, `write`, `admin`. Org-scoped keys cannot reach other tenants; platform keys (org null) are super-admin issued.

### Bootstrap the first super admin

Run once as `postgres` after the operator has signed in at least once:

```sql
select public.muster_ensure_user();  -- not needed if the user has already opened the app
update muster.users set role = 'super_admin' where lower(email) = 'anthony@28footmarketing.com';
```

## RPC surface (client contract)

Anonymous (signup page):
- `muster_countries()` -> `[{code, name, has_regions, has_profile}]`
- `muster_regions(p_country_code)` -> `[{code, name}]`
- `muster_jurisdiction_advisory(p_country_code, p_region_code, p_depth)` -> summary for anon, `full` for signed-in users
- `muster_plans()`

Signed in:
- `muster_onboarding_status()` -> `{user, organizations, self_serve_enabled, next: 'onboard' | 'workspace'}`
- `muster_onboard(p)` with `{org_name, industry, country_code, region_code, timezone, website_name, website_url, environment, preferred_name, brand:{...}}`
- `muster_my_workspace()` -> user, preferences, platform flags, organizations (each with flags, brand, advisory, members, websites, agents)
- `muster_add_website`, `muster_request_scan`, `muster_update_scan_settings`
- `muster_website_overview(p_website_id)` -> summary + compliance posture + brand + open findings + recent scans
- `muster_findings`, `muster_scans`, `muster_sitrep`, `muster_latest_sitrep`, `muster_evidence`, `muster_compliance_posture`
- `muster_org_scans(p_organization_id, p_limit default 25, p_offset default 0, p_website_id default null, p_status default null)` ->
  `{total, rows: [scan + website_name/website_url]}` — every audit run across every website in the tenant, newest first,
  paginated (`p_limit`/`p_offset`) and filterable by website or status. `muster_scans` stays per-website and capped at 100;
  this is the full tenant history.
- `muster_update_finding_status(p_finding_id, p_status, p_note)`, `muster_promote_finding_to_risk(p_finding_id)`
- `muster_brand`, `muster_save_brand(p)`, `muster_save_preferences(p)`
- `muster_invite(p_organization_id, p_email, p_role)`, `muster_claim_invites()`
- `muster_create_api_key(p_organization_id, p_agent_name, p_kind, p_scopes, p_expires_at)` (key shown once), `muster_revoke_api_key`

Super admin:
- `muster_admin_overview()`, `muster_admin_tenant(p_organization_id)`, `muster_admin_set_plan`, `muster_admin_set_flag`, `muster_admin_kill_switch`, `muster_admin_set_user_role`

Errors use SQLSTATE `42501` (forbidden, PostgREST 403), `22023` (bad input), `P0002` (not found).

## Agent gateway

`https://hjowfnzpomzxazmzywxw.supabase.co/functions/v1/muster-agent`

- `GET` returns the tool catalog (no auth).
- MCP: POST JSON-RPC 2.0 (`initialize`, `tools/list`, `tools/call`, `ping`) with header `x-muster-api-key`.
- REST: `POST {"tool":"latest_sitrep","args":{"website_id":3}}`.

Tools: `list_websites`, `website_overview`, `list_findings`, `get_evidence`, `latest_sitrep`, `get_sitrep`, `compliance_posture`, `jurisdiction_advisory` (read); `request_scan` (scan); `update_finding_status`, `promote_finding_to_risk` (write).

Claude Desktop / Claude Code config:

```json
{ "mcpServers": { "muster": { "url": "https://hjowfnzpomzxazmzywxw.supabase.co/functions/v1/muster-agent", "headers": { "x-muster-api-key": "mk_..." } } } }
```

## Scan engine

`muster-scan` is invoked two ways, both with `Authorization: Bearer <anon key>` and `x-muster-secret: <vault muster_cron_secret>`:
- `{"scan_id": N}` from `muster.do_request_scan` via pg_net (manual, api, onboarding triggers)
- `{"mode":"due","limit":3}` from pg_cron every 15 minutes (scheduled cadence per website, plus queued scans older than 2 minutes whose kick was lost)

Each scan records evidence rows (redirect chain, primary response, header set, HTTP probe, robots.txt, sitemap, security.txt, HTML excerpts), then findings that reference evidence by key. `muster.engine_ingest` assigns ids, dedupes on fingerprint, reopens or resolves, updates the scan summary, and `muster.generate_sitrep` writes the SITREP.

Posture score: 100 minus (25 per critical, 10 per high, 4 per medium, 1 per low). Bands: green >= 85, amber >= 60, red below.

## Feature flags

Resolution order: kill switch, user override, org override, plan gate, default. Flags declared but not built (`browser_wcag_engine`, `ai_narrative`, `pdf_export`, `public_status_badge`) have the kill switch on.

## Rollback

```sql
select cron.unschedule('muster-scan-due');
drop function if exists public.muster_engine_agent_call(jsonb, text, jsonb);  -- and the other public.muster_* functions
drop table if exists muster.pending_invites, muster.api_keys, muster.agents, muster.feature_flag_overrides, muster.feature_flags,
  muster.user_preferences, muster.brand_profiles, muster.jurisdiction_laws, muster.jurisdictions, muster.countries, muster.plans,
  muster.sitreps, muster.finding_evidence, muster.findings, muster.scan_evidence, muster.scans, muster.website_scan_settings, muster.scan_rules cascade;
alter table muster.organizations drop column plan, drop column country_code, drop column region_code, drop column timezone,
  drop column website_limit, drop column onboarding_status, drop column onboarding_completed_at, drop column created_by_id;
alter table muster.activity_events drop column agent_id;
delete from vault.secrets where name = 'muster_cron_secret';
```

## Dashboard wiring (v0.3.0)

`index.html` now has two modes. Demo mode is the untouched sample data set and loads by default. Live mode activates when a Supabase Auth session exists (Sign in button in the topbar): the tenant store is swapped for the user's organizations from `muster_my_workspace`, every view is rebuilt from `muster_website_overview`, and live panels are injected for the SITREP (Board Reporting), plain-English items (Plain English PDF), jurisdiction obligations (Control Mapping), agents and API keys (Super Admin Console), and the super admin tenant, flag, and user console. "Show demo" swaps back to the sample data without signing out.

Client config lives at the top of the `Live` object: project URL and the publishable key `sb_publishable_...` (public by design; RLS and RPC checks protect data).

Supabase Auth settings that must be set in the dashboard (not scriptable through MCP): Site URL and Redirect URLs must include the app origin (for example `https://muster.28footsystems.com`) for magic links and email confirmation to land back in the app.

## Phase 2 and later (not started)

- Browser engine (Playwright + axe-core) behind `browser_wcag_engine`; same evidence and finding contract.
- AI narrative SITREP behind `ai_narrative`: model writes prose constrained to the cited claims; citations are validated before save.
- Telegram alerts to CORA (chat 1238597047) on new critical findings.
- pgvector over `scan_evidence.excerpt` and `sitreps.content_md` for cross-scan semantic retrieval.
- Multi-page crawl (`website_scan_settings.max_pages`).
