# MUSTER backend (phase 1)

Product: MUSTER, by 28 Foot Systems. Target host: muster.28footsystems.com.
Data plane: shared Supabase project `mgtmqucaldkaxvxglguw`, schema `muster`, plus `public.muster_*` RPC shims.
Orchestration: Supabase Edge Functions + pg_cron. No n8n.

## What phase 1 delivers

| Partner memo item | Status | Where |
|---|---|---|
| Postgres data model | Done | `muster.*` (16 legacy Sentinel tables kept, 14 new tables) |
| Audit / finding / evidence storage | Done | `scans`, `scan_evidence`, `findings`, `finding_evidence` |
| SITREP generation | Done, deterministic | `muster.generate_sitrep()`; replaces Board Report and Plain English as sections |
| Grounded citations | Done | Every SITREP claim carries `finding_ids` and `evidence_ids`; markdown renders `[F<id>][E<id>]` |
| Reconciliation | Done for HTTP rules | Findings not observed by a completed scan auto-resolve; reappearance reopens |
| Dedupe fingerprint | Done | `sha256(website|rule|normalized_url|location)`, unique per website |
| pgvector / RAG / memory | Done | `finding_embeddings`, `evidence_embeddings` (1536-dim, IVFFLAT), `muster.embedding_queue`, `muster-backfill-embeddings` + cron job 145, `search_findings` / `search_evidence` agent tools -- see "Retrieval" below |
| Self-serve onboarding | Done | `public.muster_onboard(jsonb)` creates org, membership, appetite, brand, website, first scan |
| Jurisdiction advisor | Done | 199 countries, 101 jurisdictions, 46 law rows mapped to scan rules |
| White-label + personalization | Done | `brand_profiles` (org default, per-website override), `user_preferences` |
| Super admin + feature flags | Done | `users.role = super_admin`, `feature_flags`, `feature_flag_overrides`, `muster_admin_*` RPCs |
| Agent / AI-employee ready | Done | `agents`, `api_keys`, `muster-agent` edge function (MCP + REST) |
| Risk auto-triage | Done | `muster.autotriage()`, cron `muster-autotriage-15min`; promotes open critical/high/medium findings to `risks` + `remediation_actions` with severity-scaled due dates, auto-mitigates on rescan |
| Critical-finding tenant alerts | Done | `muster.notification_outbox`, `muster-alert-dispatch` edge function, cron `muster-alert-dispatch-5min`; emails org `executive`/`risk_owner` members via Resend when `autotriage` opens a critical/high risk. Per-org opt-out: `organizations.critical_alerts_enabled` |
| GHL sales-assisted checkout (MUSTER Partner/Enterprise) | Done | `muster-ghl-webhook`, requires a human to mark the GHL deal Closed Won -- see "Checkout paths" below |
| Stripe self-serve checkout (MUSTER base tier) | Done | Live Stripe Payment Links + `muster-stripe-webhook` + `muster.pending_commercial_grants`, applied by the existing self-serve onboarding wizard -- see "Checkout paths" below. `muster.onboard_client` (the earlier, buggy, unreachable attempt at this) stays dead and unused |

## Layout

```
supabase/
  config.toml
  migrations/
    20260904034922_muster_phase1_scan_engine.sql        rules, scans, evidence, findings, sitreps, engine, SITREP generator
    20260904035255_muster_onboarding_brand_flags_agents.sql  plans, countries, jurisdictions, laws, brand, prefs, flags, agents, keys, vault secret
    20260904035402_muster_tenancy_rls.sql               membership helpers, grants, RLS on every muster table
    20260904035802_muster_public_rpc.sql                public.muster_* surface (43 functions)
    20260904035815_muster_cron.sql                      muster-scan-due every 15 minutes
    README.md                                           filename <-> applied version contract. Read before adding one.
  functions/
    muster-scan/index.ts    HTTP-native scanner (31 rules), verify_jwt on, shared secret header
    muster-agent/index.ts   MCP (JSON-RPC 2.0, streamable HTTP) + REST gateway, API-key auth
    muster-backfill-embeddings/index.ts  drains muster.embedding_queue, shared secret header
```

The five phase-1 migrations above are the original set; many more have shipped since (retrieval, admin
URL runner, guided onboarding, cron observability). `supabase/migrations/` is the record -- this list is
not maintained per-migration. Treat the live project as the source of truth and reconcile with
`mcp__Supabase__list_migrations` rather than trusting this block.

Every migration file is named after the version `apply_migration` assigned it, which that tool takes from
its own clock and not from the filename. `supabase/migrations/README.md` is the contract: which files
consolidate several applied versions, which applied versions had no file until they were recovered from
`supabase_migrations.schema_migrations`, and the two pre-repo `sentinel` renames that are deliberately
not shipped.

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
- `muster_update_finding_status(p_finding_id, p_status, p_note)`, `muster_promote_finding_to_risk(p_finding_id)`
- `muster_brand`, `muster_save_brand(p)`, `muster_save_preferences(p)`
- `muster_invite(p_organization_id, p_email, p_role)`, `muster_claim_invites()`
- `muster_create_api_key(p_organization_id, p_agent_name, p_kind, p_scopes, p_expires_at)` (key shown once), `muster_revoke_api_key`

Super admin:
- `muster_admin_overview()`, `muster_admin_tenant(p_organization_id)`, `muster_admin_set_plan`, `muster_admin_set_flag`, `muster_admin_kill_switch`, `muster_admin_set_user_role`

Errors use SQLSTATE `42501` (forbidden, PostgREST 403), `22023` (bad input), `P0002` (not found).

## Agent gateway

`https://mgtmqucaldkaxvxglguw.supabase.co/functions/v1/muster-agent`

- `GET` returns the tool catalog (no auth).
- MCP: POST JSON-RPC 2.0 (`initialize`, `tools/list`, `tools/call`, `ping`) with header `x-muster-api-key`.
- REST: `POST {"tool":"latest_sitrep","args":{"website_id":3}}`.

Tools: `list_websites`, `website_overview`, `list_findings`, `get_evidence`, `latest_sitrep`, `get_sitrep`, `compliance_posture`, `jurisdiction_advisory`, `ai_narrative` (read); `request_scan` (scan); `update_finding_status`, `promote_finding_to_risk` (write).

`ai_narrative` is the one tool that isn't a straight SQL read: `public.muster_engine_agent_call` does the auth/org check and (if `muster.has_flag(org, 'ai_narrative')` passes) returns model context -- org/website name, posture score/band, and up to 15 open findings with their evidence ids -- and `muster-agent/index.ts` sends that to OpenRouter (`MUSTER_OPENROUTER_API_KEY` edge function secret, falling back to the project-wide `OPENROUTER_API_KEY`, model `OPENROUTER_MODEL` env override, defaults to `anthropic/claude-sonnet-5`, confirmed live against OpenRouter's own catalog) with a versioned system prompt (`muster-agent/prompt.ts`) instructing it to cite only finding/evidence ids it was given, with reasoning explicitly disabled (a short structured task; adaptive thinking would only eat the token budget) and the tool catalog attached in OpenAI function shape, validating the parsed shape (`headline`, `narrative`, `citations[]`, `confidence`), and cross-checking every citation against the finding/evidence ids the model was actually given -- any token not in the input is moved to `unverified_citations` and forces `confidence: low`, so a hallucinated reference can never pass as a verifiable one. `audience` is validated in SQL against its enum (`board`/`plain`/`technical`), not just advertised in the schema, so nothing free-form reaches the prompt. This is ephemeral -- the result is not persisted to `muster.sitreps` (see Phase 2). `ai_narrative` (`muster.feature_flags`) is **live**: `kill_switch = false`, `default_enabled = true`, `plan_minimum = pro` (verified against the table 2026-09-07, not from this document). `MUSTER_OPENROUTER_API_KEY` is set. Confirmed end to end on a real org: 7 citations, zero `unverified_citations`.

OpenRouter's `/chat/completions` is OpenAI-shaped, not Anthropic-shaped. Tools go as `{type:"function", function:{name, description, parameters}}`; the reply carries `choices[0].message.tool_calls` and `finish_reason`, and `message.content` is a string (null on a pure tool turn). Tool results go back as their own `role:"tool"` messages keyed by `tool_call_id`. Reading `stop_reason` and treating `content` as Anthropic typed blocks produced an empty `finalText` on every call, which then failed `JSON.parse` -- fixed 2026-09-07, do not reintroduce Anthropic message shapes here.

Claude Desktop / Claude Code config:

```json
{ "mcpServers": { "muster": { "url": "https://mgtmqucaldkaxvxglguw.supabase.co/functions/v1/muster-agent", "headers": { "x-muster-api-key": "mk_..." } } } }
```

## Scan engine

`muster-scan` is invoked two ways, both with `Authorization: Bearer <anon key>` and `x-muster-secret: <vault muster_cron_secret>`:
- `{"scan_id": N}` from `muster.do_request_scan` via pg_net (manual, api, onboarding triggers)
- `{"mode":"due","limit":3}` from pg_cron every 15 minutes (scheduled cadence per website, plus queued scans older than 2 minutes whose kick was lost)

Each scan records evidence rows (redirect chain, primary response, header set, HTTP probe, robots.txt, sitemap, security.txt, HTML excerpts), then findings that reference evidence by key. `muster.engine_ingest` assigns ids, dedupes on fingerprint, reopens or resolves, updates the scan summary, and `muster.generate_sitrep` writes the SITREP.

Posture score: 100 minus (25 per critical, 10 per high, 4 per medium, 1 per low). Bands: green >= 85, amber >= 60, red below.

## Feature flags

Resolution order: kill switch, user override, org override, plan gate, default. Flags declared but not built (`browser_wcag_engine`, `pdf_export`, `public_status_badge`) have the kill switch on. `ai_narrative` is built and live (see the `muster-agent` section above): kill switch off, default enabled, Pro and above.

## Retrieval (semantic search)

`search_findings` and `search_evidence` are pgvector lookups, not SQL text matches. `muster.finding_embeddings`
and `muster.evidence_embeddings` hold 1536-dim `text-embedding-3-small` vectors (IVFFLAT, L2 `<->`). The gateway
embeds the caller's query in `muster-agent/index.ts` and passes the vector to `muster_engine_search_findings` /
`muster_engine_search_evidence`, which apply org scoping in SQL. Similarity is `1 - L2^2/4` on **both** paths --
evidence used a mismatched `1 - L2` against the same 0.6 default threshold, which silently returned nothing.

Evidence lives in `muster.scan_evidence` (not `muster.evidence`, which is a near-empty legacy table); the
embedding triggers are on `findings` and `scan_evidence`.

### Keeping the index fresh

`muster.embedding_queue` carries `UNIQUE (entity_type, entity_id)`. Four triggers feed it -- INSERT and UPDATE on
each of `findings` and `scan_evidence` -- and the UPDATE triggers are gated on the columns that actually feed the
embedding text (`title`/`detail`, `excerpt`/`headers`), so a `last_seen_at` touch does not re-bill an embedding.

Two rules that are easy to get wrong and were both wrong until 2026-09-07:

- The enqueue `on conflict` must **reopen** the row (`processed_at = null, created_at = now()`), never
  `do nothing`. With `do nothing`, an entity that had been processed once could never be queued again for the
  rest of its life -- the queue was structurally incapable of representing a re-embed, and 4 of 13 findings were
  answering from vectors older than their own text.
- `insert_finding_embedding` / `insert_evidence_embedding` must upsert on `(entity_id, chunk_index)` and drain
  the queue row in the same statement. `on conflict do nothing` there made a forced re-embed a silent no-op that
  still spent an OpenRouter call.

`get_findings_without_embeddings` / `get_evidence_without_embeddings` select **queued OR missing**, oldest queue
entry first -- selecting on "no embedding row exists" alone makes a stale entity invisible to the worker.

`muster-backfill-embeddings` (cron `muster-embedding-backfill-15min`, job 145) drains the queue. It is dispatched
through `public.cron_safe_post`, so a failed HTTP call lands in `public.edge_invocations` instead of being
reported as a successful cron run. It authenticates with `x-muster-secret` against `public.muster_engine_secret()`
-- before that check existed the endpoint was anonymous and spent real OpenRouter credit per record. A 401, 402,
403 or 429 from the provider raises `FatalEmbedError` and aborts the run rather than burning one request per
remaining record against a dead key.

### Contract tests

`muster.test_retrieval_contract()` (invoker rights, no grants) is the regression gate -- 12 tests covering the
similarity formula on both paths, `search_path` well-formedness, grant lockdown, org scoping, evidence dedupe and
linkage, index completeness, and staleness. Run it after anything that touches retrieval:

```sql
select * from muster.test_retrieval_contract();
```

`search_path` on these functions must be written as `set search_path = public, muster` (two identifiers). Writing
`SET search_path TO 'public, muster'` stores one quoted identifier, `pg_catalog` gets prepended, `muster` is never
on the path, and every `<->` fails with `operator does not exist: public.vector <-> public.vector`. Eight functions
shipped that way and both search wrappers were dead end to end.

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

## Checkout paths

Resolved 2026-09-08 (`.planning/autonomy/BLOCKERS-AND-DECISIONS.md` B-1): **MUSTER base tier is Stripe self-serve; MUSTER Partner/Enterprise stay GHL sales-assisted.** Two genuinely different commercial motions for two genuinely different tiers, not an accidental duplicate.

- **MUSTER base tier -- Stripe self-serve (live).** Two live Payment Links, one per pricing stage (`https://buy.stripe.com/eVqbJ26yL2hw3gL2x3gIo0t` seed, `https://buy.stripe.com/bJeeVe5uHaO2bNhb3zgIo0u` fruit), each carrying `metadata: {tier, stage}`. `muster-stripe-webhook` verifies the Stripe signature, handles `checkout.session.completed`, invites the Supabase Auth user if new, and records a `muster.pending_commercial_grants` row keyed by email -- **it does not create the organization itself**. The organization is created the normal way, when the buyer actually runs the existing self-serve onboarding wizard in `app.html` (`muster_onboard` -> `muster.do_onboard`); `do_onboard` now checks for a pending grant matching the user's email right after creating the org and applies the real plan/stage instead of leaving it on `trial`. Deliberately reuses the already-verified onboarding path instead of building a second one. Product: `prod_VCwq3MBRwc16WC`. Prices: `price_1UCWx0JijfcmbDDBLEFrn3Et` (seed, $97/mo), `price_1UCWx0JijfcmbDDBKaHbJyGW` (fruit, $197/mo) -- also recorded in `muster.commercial_pricing.stripe_price_id`.
  - Requires the `STRIPE_WEBHOOK_SECRET` edge function secret (from registering the webhook endpoint in the Stripe dashboard, pointed at `muster-stripe-webhook`, subscribed to `checkout.session.completed` -- not done via MCP, no tool exposes webhook-endpoint creation).
- **MUSTER Partner/Enterprise -- GHL sales-assisted (live).** Unchanged: a human marks a GHL deal Closed Won, its workflow calls `muster-ghl-webhook`, which calls `public.muster_ghl_provision`.
- **`muster.onboard_client`:** stays dead and unused (deployed 2026-09-06, no caller, buggy `organization_members.role = 'owner'` insert -- see migration `20260906012143`'s header comment). The Stripe flow above does not use it and never will; do not resurrect it.

## Critical-finding alerts

`muster.autotriage()` (cron `muster-autotriage-15min`, offset `:07/:22/:37/:52` to avoid stampeding `muster-scan-due`) queues one row in `muster.notification_outbox` per newly-opened critical/high risk, addressed to that org's `executive`/`risk_owner` members, unless `organizations.critical_alerts_enabled = false`. `muster-alert-dispatch` (cron every 5 minutes) claims pending rows via `public.muster_engine_claim_alerts` and sends through Resend (`RESEND_API_KEY` edge function secret; from address `alerts@mail.28footsystems.com`). A failed send is requeued to `pending` for up to 5 total attempts (the 5-minute cron interval is the backoff), then dead-lettered to a terminal `failed` status, visible via `muster_admin_overview().alerts`. One alert per risk id, ever (unique index on `notification_outbox(entity_type, entity_id, category)`).

## Phase 2 and later (not started)

- Browser engine (Playwright + axe-core) behind `browser_wcag_engine`; same evidence and finding contract.
- Persist `ai_narrative` output into `muster.sitreps.sections` (today it's an ephemeral `muster-agent` tool call, not saved).
- Telegram alerts to CORA (chat 1238597047) on new critical findings.
- pgvector over `scan_evidence.excerpt` and `sitreps.content_md` for cross-scan semantic retrieval.
- Multi-page crawl (`website_scan_settings.max_pages`).
