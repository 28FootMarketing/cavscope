# MUSTER backend (phase 1)

Product: MUSTER, by 28 Foot Systems. Target host: muster.28footsystems.com.
Data plane: Supabase project `hjowfnzpomzxazmzywxw`, schema `muster`, plus `public.muster_*` RPC shims. (The shared 28FS project `mgtmqucaldkaxvxglguw` ran MUSTER until 2026-09-08 and runs none of it now; see `supabase/migrations/MUSTER-PROJECT-LEDGER.md`.)
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

### Forced password change

An account provisioned with a temporary password carries
`app_metadata.force_password_change`. As of migration `20260915230805` that flag is enforced,
by `muster.password_change_required()` — a predicate over the caller's own JWT claims, wired
into the six functions that are the authorization spine: `current_user_id`, `is_super_admin`,
`org_role`, `shares_org_with`, `onboarding_caller`, `ensure_user_from_auth`. A flagged caller
resolves to no user id, no super-admin and no role in any organization, so every tenant-scoped
RPC and every RLS policy that routes through them answers empty or raises `42501`.

Before that migration **nothing read the flag at all** — not a page, not a policy, not a
function. It was set on a live `super_admin` account, which signed in on the old password and
went straight to the workspace while the account list said a change was required. A control
nobody checks still reads as satisfied to whoever audits it, which is worse than no control.

Spine coverage was measured, not assumed: of the `public.muster_*` functions executable by
`authenticated`, exactly five bypass the spine (`muster_countries`, `muster_plans`,
`muster_regions`, `muster_public_pricing`, `muster_jurisdiction_advisory`) and all five return
public reference data. Of 79 RLS policies in schema `muster`, the 27 that bypass the spine are
24 `to muster_app` (a non-browser role) plus 3 catalog reads.

Clearing the flag needs the service role, so it goes through the **`muster-set-password`** edge
function, which sets the new password and clears the flag in one admin call or neither. There is
deliberately no "clear the flag" endpoint — that would be a bypass with extra steps. The browser
then **must** call `refreshSession()`: JWT claims are minted at sign-in and not read live, so
until the token is replaced the gate still sees the old claim and the workspace looks broken.

`service_role` is exempt by construction rather than by an exception clause: a service-role JWT
carries no `app_metadata`, so the predicate is already false for it. An edge function that
forwards a *user's* `Authorization` header (`muster-verify-site` does) is correctly gated.

Break-glass, if the gate ever locks someone out with no way through — it cannot lock anyone out
of the Supabase dashboard:

```sql
update auth.users
   set raw_app_meta_data = raw_app_meta_data - 'force_password_change'
 where email = 'someone@example.com';
```

They must then sign out and back in, for the same claims-are-minted reason.

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

`https://hjowfnzpomzxazmzywxw.supabase.co/functions/v1/muster-agent`

- `GET` returns the tool catalog (no auth).
- MCP: POST JSON-RPC 2.0 (`initialize`, `tools/list`, `tools/call`, `ping`) with header `x-muster-api-key`.
- REST: `POST {"tool":"latest_sitrep","args":{"website_id":3}}`.

Tools: `list_websites`, `website_overview`, `list_findings`, `get_evidence`, `latest_sitrep`, `get_sitrep`, `compliance_posture`, `jurisdiction_advisory`, `ai_narrative` (read); `request_scan` (scan); `update_finding_status`, `promote_finding_to_risk` (write).

`ai_narrative` is the one tool that isn't a straight SQL read: `public.muster_engine_agent_call` does the auth/org check and (if `muster.has_flag(org, 'ai_narrative')` passes) returns model context -- org/website name, posture score/band, and up to 15 open findings with their evidence ids -- and `muster-agent/index.ts` sends that to **the tenant's own LLM** (see *Tenant-supplied LLM* below -- as of migration 071 this path no longer uses a MUSTER credential at all, and an organization with nothing configured gets no narrative rather than ours) with a versioned system prompt (`muster-agent/prompt.ts`) instructing it to cite only finding/evidence ids it was given, with reasoning explicitly disabled where the provider understands that flag (a short structured task; adaptive thinking would only eat the token budget -- but it is an OpenRouter extension, see below) and the tool catalog attached in OpenAI function shape, validating the parsed shape (`headline`, `narrative`, `citations[]`, `confidence`), and cross-checking every citation against the finding/evidence ids the model was actually given -- any token not in the input is moved to `unverified_citations` and forces `confidence: low`, so a hallucinated reference can never pass as a verifiable one. `audience` is validated in SQL against its enum (`board`/`plain`/`technical`), not just advertised in the schema, so nothing free-form reaches the prompt. This is ephemeral -- the result is not persisted to `muster.sitreps` (see Phase 2). `ai_narrative` (`muster.feature_flags`) is **live**: `kill_switch = false`, `default_enabled = true`, `plan_minimum = pro` (verified against the table 2026-09-07, not from this document). `MUSTER_OPENROUTER_API_KEY` is set (embeddings only now). The 7-citation, zero-`unverified_citations` end-to-end run on a real org was against MUSTER's OpenRouter key, before 071 moved this path onto tenant credentials; it is evidence about the prompt and the citation check, not about the credential plumbing that replaced it.

OpenRouter's `/chat/completions` is OpenAI-shaped, not Anthropic-shaped. Tools go as `{type:"function", function:{name, description, parameters}}`; the reply carries `choices[0].message.tool_calls` and `finish_reason`, and `message.content` is a string (null on a pure tool turn). Tool results go back as their own `role:"tool"` messages keyed by `tool_call_id`. Reading `stop_reason` and treating `content` as Anthropic typed blocks produced an empty `finalText` on every call, which then failed `JSON.parse` -- fixed 2026-09-07, do not reintroduce Anthropic message shapes here.

Claude Desktop / Claude Code config:

```json
{ "mcpServers": { "muster": { "url": "https://hjowfnzpomzxazmzywxw.supabase.co/functions/v1/muster-agent", "headers": { "x-muster-api-key": "mk_..." } } } }
```

### Tenant-supplied LLM (BYO)

Migrations `069`/`070`/`071`, wired into `muster-agent` the same day. One row per organization in
`muster.org_llm_config`: an OpenAI-shaped `base_url`, a `model`, and a key in **Vault** (the table
holds a `secret_id` and the last four characters, never the key).

**Scope, decided deliberately.** The `ai_narrative` tool and the agent loop. **Not embeddings** --
`finding_embeddings`, `evidence_embeddings` and the doc chunks are all pinned to `vector(1536)`, so a
tenant model with different dimensions breaks retrieval outright and one with the same dimensions
silently poisons it. Re-embedding a tenant's corpus is an operation, not a setting. Say that to a
client rather than glossing it. Embeddings therefore still run on `MUSTER_OPENROUTER_API_KEY`, and a
tenant's *query text* still reaches MUSTER's embedding provider; only the narrative does not.

**No silent fallback, in either direction.** An organization with no row gets **no LLM** -- the call
fails with a message naming who can configure one, and that tenant stays on the deterministic SITREP
generator that produced all 42 reports in this database. Falling back to MUSTER's account would
defeat the entire feature, so `runAgentLoop` cannot reach `openRouterKey()` at all and
`tests/agent/llm.test.ts` asserts the single remaining call site is `embedText`.

**The tenant is resolved from the website, not from the API key.** `muster_engine_agent_call` scopes
`ai_narrative` by `muster.website_org(website_id)` and only refuses when the key *is* org-scoped and
the orgs differ -- so a platform-scoped key (`organization_id` null) may narrate any tenant's site.
Keying the credential off the API key would have found no config there, and the natural-looking fix
would have sent that tenant's findings to MUSTER's provider through the one feature built to stop
exactly that, with nothing failing. `public.muster_engine_llm_config_for_website(website_id)` does
the mapping in SQL, so the edge function never names an organization and cannot ask for the wrong
tenant's key.

**Reading the config: two functions, on purpose.**

| Function | Returns the key? | Callable by |
| --- | --- | --- |
| `public.muster_llm_config(org)` | No -- four-character hint | `authenticated` (org member) |
| `public.muster_set_llm_config(org, url, model, key, label)` | No | `authenticated` (org executive or super admin) |
| `public.muster_clear_llm_config(org)` | No -- also deletes the Vault secret | `authenticated` (org executive or super admin) |
| `public.muster_engine_llm_config(org)` | **Yes** | `service_role` only |
| `public.muster_engine_llm_config_for_website(website)` | **Yes** | `service_role` only |
| `public.muster_engine_record_llm_result(org, ok, error)` | n/a | `service_role` only |

The three engine functions are revoked from `anon` **and** `authenticated` by name, per the standing
rule: Supabase's default privileges grant EXECUTE on every new `public` function to both roles and
`revoke ... from public` does not undo it. Getting that wrong here does not leak a scan result, it
leaks a customer's API key.

**A tenant-supplied URL is an SSRF vector** -- an edge function fetches it carrying a bearer token.
`muster.is_valid_llm_endpoint()` refuses anything but absolute https to a public host: loopback,
RFC 1918, RFC 6598 CGNAT, IPv6 ULA and `169.254.0.0/16` (where cloud instance metadata lives) are
refused by literal. It is a `CHECK` constraint **and** an RPC validation **and**, since the wiring,
`isSafeLlmEndpoint()` in `muster-agent/llm.ts`, which re-checks at call time -- a guard enforced only
on the write path is enforced at the wrong end. The two copies are kept in step by a parity test.

**`reasoning: {enabled: false}` is an OpenRouter extension** and is sent only to OpenRouter. OpenAI
and Azure reject an unrecognised top-level parameter with a 400, so the body that always worked
against the platform key would have failed every call against a tenant's own OpenAI account -- and
been reported to them as a bad key.

**Failures are recorded and shown.** `muster_engine_record_llm_result` writes `last_ok_at` /
`last_error` / `last_error_at`, which `muster_llm_config` returns, so an expired or revoked tenant
key is visible rather than degrading to silence. A model that returns prose instead of JSON is
recorded the same way as a transport failure, because to the operator both mean "my model did not
produce a narrative". Everything written there goes through `redactSecret()` first: a provider that
quotes the presented credential in its 401 body would otherwise put a live key on a page, through
the one feature built to keep keys off pages.

**Still outstanding:** no workspace UI sets a config yet, so today it is set by an org executive
calling `muster_set_llm_config` (or by a super admin). Nothing in a browser can reach the key either
way.

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

`index.html` now has two modes. Demo mode is the untouched sample data set and loads by default. Live mode activates when a Supabase Auth session exists (Sign in button in the topbar): the tenant store is swapped for the user's organizations from `muster_my_workspace`, every view is rebuilt from `muster_website_overview`, and live panels are injected for the SITREP (Board Reporting), plain-English items (Plain English PDF), jurisdiction obligations (Control Mapping), agents, API keys, report branding and the tenant's own LLM (Team & Settings). Platform administration is not in this page: since 2026-09-23 every super admin control lives in `admin.html` at `/admin`, and `app.html` only links to it. "Show demo" swaps back to the sample data without signing out.

Client config lives at the top of the `Live` object: project URL and the publishable key `sb_publishable_...` (public by design; RLS and RPC checks protect data).

Supabase Auth settings that must be set in the dashboard (not scriptable through MCP): Site URL and Redirect URLs must include the app origin (for example `https://muster.28footsystems.com`) for magic links and email confirmation to land back in the app.

## Checkout paths

Resolved 2026-09-08 (`.planning/autonomy/BLOCKERS-AND-DECISIONS.md` B-1): **MUSTER base tier is Stripe self-serve; MUSTER Partner/Enterprise stay GHL sales-assisted.** Two genuinely different commercial motions for two genuinely different tiers, not an accidental duplicate.

- **MUSTER base tier -- Stripe self-serve (live).** Two live Payment Links, one per pricing stage (`https://buy.stripe.com/eVqbJ26yL2hw3gL2x3gIo0t` seed, `https://buy.stripe.com/bJeeVe5uHaO2bNhb3zgIo0u` fruit), each carrying `metadata: {tier, stage}`. `muster-stripe-webhook` verifies the Stripe signature, handles `checkout.session.completed`, invites the Supabase Auth user if new, and records a `muster.pending_commercial_grants` row keyed by email -- **it does not create the organization itself**. The organization is created the normal way, when the buyer actually runs the existing self-serve onboarding wizard in `app.html` (`muster_onboard` -> `muster.do_onboard`); `do_onboard` now checks for a pending grant matching the user's email right after creating the org and applies the real plan/stage instead of leaving it on `trial`. Deliberately reuses the already-verified onboarding path instead of building a second one. Product: `prod_VCwq3MBRwc16WC`. Prices: `price_1UCWx0JijfcmbDDBLEFrn3Et` (seed, $97/mo), `price_1UCWx0JijfcmbDDBKaHbJyGW` (fruit, $197/mo) -- also recorded in `muster.commercial_pricing.stripe_price_id`.
  - Requires the `STRIPE_WEBHOOK_SECRET` edge function secret (from registering the webhook endpoint in the Stripe dashboard, pointed at `muster-stripe-webhook`, subscribed to `checkout.session.completed` -- not done via MCP, no tool exposes webhook-endpoint creation).
- **MUSTER Partner/Enterprise -- GHL sales-assisted (live).** Unchanged: a human marks a GHL deal Closed Won, its workflow calls `muster-ghl-webhook`, which calls `public.muster_ghl_provision`.
- **`muster.onboard_client`:** stays dead and unused (deployed 2026-09-06, no caller, buggy `organization_members.role = 'owner'` insert -- see migration `20260906012143`'s header comment). The Stripe flow above does not use it and never will; do not resurrect it.

## Critical-finding alerts

`muster.autotriage()` (cron `muster-autotriage-15min`, offset `:07/:22/:37/:52` to avoid stampeding `muster-scan-due`) queues one row in `muster.notification_outbox` per newly-opened critical/high risk, addressed to that org's `executive`/`risk_owner` members, unless `organizations.critical_alerts_enabled = false`. `muster-alert-dispatch` (cron every 5 minutes) claims pending rows via `public.muster_engine_claim_alerts` and sends through Resend (`RESEND_API_KEY` edge function secret; from address `alerts@mail.cavscope.28footsystems.com` as of 2026-09-26, overridable via the `MUSTER_ALERT_FROM` secret -- was `alerts@mail.muster.partners`, switched after a real recipient noticed the sending domain still said muster despite the "CavScope Alerts" display name). `mail.cavscope.28footsystems.com` is fully verified in Resend (DKIM, SPF, MX) with sending enabled; `mail.muster.partners` and the older `mail.28footsystems.com` are both still verified too, so nothing breaks if this needs to roll back. A failed send is requeued to `pending` for up to 5 total attempts (the 5-minute cron interval is the backoff), then dead-lettered to a terminal `failed` status, visible via `muster_admin_overview().alerts`. One alert per risk id, ever (unique index on `notification_outbox(entity_type, entity_id, category)`). Sent as multipart HTML + text, branded, with an `Idempotency-Key` of the outbox row id so a retry after a network timeout cannot double-send.

`risk_opened` is the only category the outbox accepts -- the check constraint permits nothing else -- so it is the only application email MUSTER sends today. **Auth email is a completely separate path**: magic link, invite, signup confirmation, email change, password reset and reauthentication are sent by Supabase Auth (GoTrue), not by any function here, and reach Resend only because Resend is configured as Supabase's SMTP relay. Their templates live in Supabase project config, sourced from `supabase/auth-email-templates/`, and none of that migrates between projects. Full routing map, SMTP settings and the redirect allowlist: `docs/EMAIL.md`.

## Phase 2 and later (not started)

- Browser engine (Playwright + axe-core) behind `browser_wcag_engine`; same evidence and finding contract.
- Persist `ai_narrative` output into `muster.sitreps.sections` (today it's an ephemeral `muster-agent` tool call, not saved).
- Telegram alerts to CORA (chat 1238597047) on new critical findings.
- pgvector over `scan_evidence.excerpt` and `sitreps.content_md` for cross-scan semantic retrieval.
- Multi-page crawl (`website_scan_settings.max_pages`).
