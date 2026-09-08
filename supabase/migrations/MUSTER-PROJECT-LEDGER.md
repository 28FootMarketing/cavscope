# `hjowfnzpomzxazmzywxw` migration ledger

`supabase/migrations/*.sql` in this directory is the ledger for the **old shared**
project `mgtmqucaldkaxvxglguw`. MUSTER's own dedicated project is
`hjowfnzpomzxazmzywxw`, and its migrations are **not** in this directory yet.

That is a known, recorded gap, not an oversight. It is the same failure mode PR #46
fixed for the other project, so it does not get to happen quietly twice.

## Applied to `hjowfnzpomzxazmzywxw`

| Version | Name |
|---|---|
| 20260907204744 | muster_000_extensions |
| 20260907204804 | muster_001_vector_into_public_to_match_source |
| 20260907204829 | muster_002_platform_cron_helpers |
| 20260907205957 | muster_003_baseline_core_tables |
| 20260907210029 | muster_004_baseline_guards_rls_touch |
| 20260907212647 | muster_005_remaining_tables_from_live |
| 20260907222444 | muster_006_keys_and_unique_constraints |
| 20260907222529 | muster_007_check_constraints |
| 20260907222604 | muster_008_foreign_keys |
| 20260907222630 | muster_009_indexes |
| 20260907222744 | muster_010_baseline_table_drift |
| 20260907222801 | muster_011_baseline_index_drift |
| 20260907223344 | muster_012_helper_functions_sql |
| 20260907233303 | muster_013_functions_batch1_engine_core |
| 20260907233505 | muster_014_functions_batch2_onboard_triage_claim |
| 20260907233742 | muster_015_functions_batch3_queries_and_triggers |
| 20260907233858 | muster_016_fix_doubled_backslashes_from_batch3 |
| 20260907233924 | muster_017_fix_disclaimer_backslashes |
| 20260907234001 | muster_018_align_touch_updated_at_to_source |
| 20260907234811 | muster_019_rls_policies_triggers_and_shims_part1 |
| 20260907235048 | muster_020_shims_part2_final |
| 20260907235148 | muster_021_execute_grants_lockdown |
| 20260907235321 | muster_022_grants_reconcile_to_source |
| 20260908001x | muster_023_temporary_bulk_import_endpoint (dropped by 026) |
| 20260908001x | muster_024_fix_check_constraints_and_partial_indexes |
| 20260908002x | muster_025_resync_identity_sequences_after_import |
| 20260908002x | muster_026_drop_bulk_import_endpoint |
| 20260908003x | muster_027_embedding_backfill_rpcs |
| 20260908004x | muster_028_cron_jobs_inactive_until_cutover |
| 20260908014043 | muster_029_autotriage_alert_url_to_muster_partners |

## The files now exist

**`supabase/migrations/`** — all 29, exported from that project's own
`supabase_migrations.schema_migrations` ledger, **every file byte-identical to the
statement Postgres recorded as applied** (17 md5-match outright, 13 match once a single
trailing newline is appended — see that directory's README). Not a reconstruction from the
catalog or from memory.

They are in their own directory, not merged into this one, because `supabase db push`
applies whatever it finds in `supabase/migrations/` to whichever project the CLI is
linked to. One directory holding two projects' histories is a loaded gun. At
decommission, archive this directory and rename that one to `migrations/`.

They were generated from the **live catalog** of `mgtmqucaldkaxvxglguw` rather than
replayed from this directory, because 24 of 39 files here differ from what was actually
applied and the drift is concentrated in function bodies.

## Verified state (2026-09-07)

Checked by checksum against source, not by reading.

| Layer | Result |
|---|---|
| Tables / columns / PKs / uniques / checks / FKs / indexes | 45 / 490 / 45 / 12 / 79 / 91 / 122, all matching |
| `muster.*` functions | 58 / 58. md5 over all but `do_request_scan` = `93d046b0e446fb63a595a3e46c12742e` on both |
| `public.muster_*` shims | 70 / 70. md5 over all but `muster_create_api_key` = `585cac24f881952f3ea93da8c7ebfbbe` on both |
| RLS enabled | 45 / 45 |
| Policies | 79 / 79. md5 over table, name, permissive, cmd, roles, using, with-check = `790ddb11ca7e2b79ee7fefcf91f8ed58` on both |
| Triggers | 25 / 25 |
| EXECUTE grants | 128 functions, same buckets: 44 service_role only, 63 authenticated, 5 anon, 6 postgres only, 10 still PUBLIC |

### The three intended differences

1. **`muster.do_request_scan`** hardcodes the Supabase URL it POSTs to when kicking the
   scan engine. Here it points at this project. Copied verbatim, this project would have
   queued scans locally and executed them on the old one, writing results there.
2. **`public.muster_create_api_key`** returns an `mcp_url` telling the caller where to
   point their agent. Same reasoning, same fix.
3. **`public.muster_public_pricing`** carries a leftover `PUBLIC` execute grant on source
   alongside its explicit `anon` grant. This project has only the explicit grant.
   Identical reach, since anon is inside PUBLIC, on an endpoint meant to be public. Not
   replicated: this project is the stricter of the two and stays that way.

Grants were the one layer that did not come along for free, in both directions. Postgres
grants EXECUTE to PUBLIC on every newly created function, so a fresh project starts
*more* permissive than the source it was copied from: until `muster_021`/`muster_022`,
anon could call every engine internal, every vault secret reader and every admin RPC
here. The bodies check `is_super_admin()` and would have raised, but failing safely is
not the same as being unreachable. Then the blanket `revoke ... from public` that fixed
it took service_role with it on 24 functions, because service_role only ever held those
through PUBLIC, which would have locked the edge functions out of the engine. Both
directions were caught by comparing ACL checksums, not by inspection.

## Data, edge functions and cron (2026-09-08)

### Data: complete and verified

708 rows. All 42 non-embedding tables are **byte-identical** to source:
`md5 = 72d0f9272093896fb769e3116c3e1f38` on both projects, over every column of every
row including 118 KB of SITREP markdown and 107 KB of scan evidence.

It was moved **server-to-server**, not through a transcript: a token-gated import
endpoint on this project (`muster_023`), driven by `pg_net` from the source, in seven
dependency-ordered waves. The endpoint was dropped the moment the data landed
(`muster_026`), along with its source-side helper. 300 KB moved without any of it
being retyped.

Embeddings were **not** copied. The 77 vectors are ~1.2 MB as text and are derived
data, so the insert triggers queued them automatically on arrival and
`muster-backfill-embeddings` regenerated them through OpenRouter: 13 finding + 64
evidence embeddings, queue fully drained, matching source counts exactly.

`muster_025` resynced every identity sequence. Without it the first insert into any
migrated table would have collided with a copied primary key.

### What the data migration exposed

- **`users_role_check` was missing `super_admin`** and rejected the admin row on
  import. `muster_024` repaired it. It was invisible until then because the earlier
  structural verification compared *counts* (79 checks, 122 indexes), and a count
  proves nothing about content. Every structural object is now compared by definition.
- **Six `public.*` RPCs had never been migrated** (`get_findings_without_embeddings`,
  `insert_finding_embedding` and four siblings). `muster_019`/`muster_020` selected
  shims by the name prefix `muster%` and these do not carry it, so the "70/70 shims"
  checksum was true and useless simultaneously: it verified the set it had defined,
  not the set the system needs. Without them semantic search returns nothing, silently.
  Fixed in `muster_027`.
- **`public.apply_approved_kb_updates()` on the shared project writes into
  `muster.jurisdiction_laws`.** It is CORA/JARVIS code, not MUSTER's, so it was
  deliberately left on `mgtmqucaldkaxvxglguw` -- but after cutover it will be updating
  a `muster` schema that is no longer the live one. **This needs a decision.**

### Edge functions: 8 of 8 deployed

| Function | verify_jwt | Notes |
|---|---|---|
| `muster-scan` | true | |
| `muster-agent` | false | two files (`index.ts` + `prompt.ts`) |
| `muster-alert-dispatch` | true | `ezbr_sha256` identical to source v7 |
| `muster-watchdog` | false | |
| `muster-backfill-embeddings` | false | proven working end to end |
| `muster-verify-site` | true | source had no repo copy; recovered and committed |
| `muster-stripe-webhook` | false | needs `STRIPE_WEBHOOK_SECRET` |
| `muster-ghl-webhook` | false | needs `GHL_API_KEY`, `GHL_LOCATION_ID`, and the `muster_ghl_webhook_secret` vault entry |

None of them hardcodes a project ref; they read `SUPABASE_URL` from the runtime.

Vault on this project now holds `muster_cron_secret` (generated fresh -- it does not
need to match the old project, since both sides read it from their own vault) and
`supabase_anon_key`.

### Cron: 5 of 5 created, all INACTIVE

Commands match source exactly modulo the project ref:
`md5 = 5598b54e56989443729029c6a5e9c297` on both.

They are inactive on purpose. The frontend still talks to the old project and the old
project's cron is still running. Turning these on now would scan the same two client
websites twice every 15 minutes, diverge this project's data from the byte-identical
copy above, and dead-letter real alerts against a project with no `RESEND_API_KEY`.

**Cutover is one switch, after the frontend is repointed:**

```sql
-- on hjowfnzpomzxazmzywxw
select cron.alter_job(jobid, active := true)  from cron.job where jobname like 'muster%';
-- on mgtmqucaldkaxvxglguw, same maintenance window
select cron.alter_job(jobid, active := false) from cron.job where jobname like 'muster%';
```

`cron.alter_job`, not `update cron.job` -- this role has EXECUTE on the former and no
write privilege on the latter.

## Still missing on `hjowfnzpomzxazmzywxw`

- **Edge function secrets**: `RESEND_API_KEY`, `STRIPE_WEBHOOK_SECRET`, `GHL_API_KEY`,
  `GHL_LOCATION_ID`, and the `muster_ghl_webhook_secret` vault entry (must match what
  GHL sends). `MUSTER_OPENROUTER_API_KEY` is present and confirmed working.
- **The 3 auth users.** Password hashes do not migrate. `muster.users.auth_user_id`
  has no FK to `auth.users`, so the rows carried their original uuids across and will
  re-link cleanly if the auth users are recreated with those same uuids.
- **Frontend `SB_URL`/`SB_KEY`** in `index.html`, `signin.html`, `app.html`,
  `sitrep.html`, `onboarding.html`.
- **Supabase Auth config**: SMTP, the six templates, Site URL, redirect allowlist
  (`docs/EMAIL.md`). None of it migrates between projects.
- **Stripe webhook repoint.**
- **The `apply_approved_kb_updates()` cross-boundary decision** described above.
- ~~The migration files themselves.~~ **Done** — `supabase/migrations/`,
  29 files, checksum-verified against the applied ledger.

## Two stale hostnames -- both fixed on both projects (2026-09-08)

Both were copied forward byte-identically during the migration to keep the parity
checksums meaningful, then fixed on BOTH projects in one pass so they could not drift
apart.

### `muster.autotriage()` alert body

`View full detail: https://app.muster.28footsystems.com/` ->
`View full detail: https://app.muster.partners/app`.

The HTML half of the same email already pointed at `MUSTER_APP_URL` (default
`https://app.muster.partners/app`) from `muster-alert-dispatch`, so a recipient reading
the HTML part and one on a text-only client were being sent to two different places.

Applied by reading the body back out of `pg_get_functiondef()` and rewriting it with
`replace()` -- not by restating a 5 KB plpgsql body. Retyping is what caused
`muster_016` and `muster_017`; it is not the tool used to fix things.

| Project | Version | Name | File md5 |
|---|---|---|---|
| `mgtmqucaldkaxvxglguw` | 20260908014037 | muster_autotriage_alert_url_to_muster_partners | `c81fab6147fd76265f0c524ea6c698f1` |
| `hjowfnzpomzxazmzywxw` | 20260908014043 | muster_029_autotriage_alert_url_to_muster_partners | `13fb79d90f2922ecf156bd2fb0a582b1` |

Both files match the statement text Postgres recorded as applied. `muster.autotriage()`
is now `md5 2889bd9bd71ad0bc34239a0ef8c5fc34` on both projects.

**This URL is a literal in two places** -- `muster.autotriage()` and `MUSTER_APP_URL`'s
default in `muster-alert-dispatch/index.ts`. Change them together.

### `muster-scan` User-Agent

`+https://muster.28footsystems.com/scanner` -> `+https://muster.partners`.

The old URL 404s twice over: no `/scanner` page was ever built, and
`muster.28footsystems.com` is not a host `middleware.js` routes at all. A
self-identifying crawler UA whose URL does not resolve defeats its own purpose.

The same host was stale in three more places found by sweeping the whole
`supabase/functions/` tree rather than only the two the earlier pass had recorded:

| File | Was | Now |
|---|---|---|
| `muster-scan/index.ts` | scanner UA `+https://muster.28footsystems.com/scanner` | `+https://muster.partners` |
| `muster-verify-site/index.ts` | verify UA `(+https://muster.28footsystems.com)` | `(+https://muster.partners)` |
| `muster-agent/index.ts` | OpenAPI `info.contact.url`, plus `http-referer` on both OpenRouter calls | `https://muster.partners` |
| `muster-backfill-embeddings/index.ts` | `http-referer` on the OpenRouter embeddings call | `https://muster.partners` |

All four redeployed to BOTH projects from the repo, byte-identical bundles:

| Function | `mgtmqucaldkaxvxglguw` | `hjowfnzpomzxazmzywxw` | ezbr_sha256 |
|---|---|---|---|
| muster-scan | v8 | v3 | `210560cec2fdb88461eda824cbe501185630db139cfed3fa577b09d0bb6945e0` |
| muster-agent | v13 | v2 | `8fbaa372a9f549065b0ea747cb9b3de19352d18c125652ac86ce48658902dbc6` |
| muster-backfill-embeddings | v12 | v2 | `04f9e983198feb24d1fc909c3d26383bdb5e48d40c33110a765a5c76de16aec6` |
| muster-verify-site | v5 | v2 | `efdff4aff7be9d75f62a92ce898546e7f13b676003c97ecc1afb484e2f56966f` |

`verify_jwt` was preserved per function (`true` on scan and verify-site, `false` on
agent and backfill). `muster-agent` ships two files -- `index.ts` and `prompt.ts` --
and both go in every deploy; deploying `index.ts` alone breaks its import.

The one remaining `28footsystems` reference in `supabase/functions/` is the comment in
`muster-alert-dispatch/index.ts` recording that `mail.28footsystems.com` is still a
verified Resend domain. That is accurate history, not a stale pointer.

### All 8 edge functions now byte-identical across both projects

`muster-watchdog`, `muster-stripe-webhook` and `muster-ghl-webhook` had been reporting
different `ezbr_sha256` on the two projects. Two causes, not one, and they had to be
separated before either could be fixed.

**Cause 1 -- the deploy tool.** Those three were last deployed to
`mgtmqucaldkaxvxglguw` by a different tool than the MCP `deploy_edge_function` used for
every deploy on the new project. The tell is in the old project's rows: an
`entrypoint_path` carrying a build index that does not match `version`
(`..._1/source/index.ts` at version 4), and `created_at` equal to `updated_at`. Two
bundlers, identical source, two hashes.

Normalizing is therefore a redeploy through the same tool, using each function's own
live source so nothing changes semantically. `muster-watchdog` and
`muster-stripe-webhook` both landed exactly on the hash the new project already had,
which is the proof the content was never different:

| Function | `mgtmqucaldkaxvxglguw` | `hjowfnzpomzxazmzywxw` | ezbr_sha256 |
|---|---|---|---|
| muster-watchdog | v5 | v2 | `107274210ee24d3297eea5f8b5a5e2b3fb4a0a7debe66d483d1bb1b12ba48b67` |
| muster-stripe-webhook | v6 | v1 | `bf4d9af61c12b6f5552b91bfe681a7ffd5f7e1d98f63f3b363ea03b440cd23ca` |
| muster-ghl-webhook | v9 | v2 | `e220d2c8396c7008a72ba6c91d16f51e52db5bab07202c7ce056567b152f2783` |

**Cause 2 -- `muster-ghl-webhook` really did differ, and this repo was the stale side.**
Redeploying its live source produced a *third* hash rather than the new project's,
which is what exposed it. The difference was seven lines of header comment: the live
function on `mgtmqucaldkaxvxglguw` documented the `custom_fields` diagnostic's `model`
parameter (`"model": "contact"|"opportunity"`, default `contact`); this repo's copy
described the diagnostic as if it took no parameter. The code supported `model` in both
copies -- only the documentation lagged, and only here. The repo was corrected to the
live text, then that text was deployed to the new project, which is why all three now
read `e220d2c8...`.

Worth keeping in mind: a matching hash across the two projects proves the two projects
agree. It does not prove either agrees with this repo. `muster-ghl-webhook` is the case
where those came apart, and the only reason it surfaced is that a redeploy produced a
hash nobody had seen before.

**Every MUSTER edge function is now identical on both projects and identical to this
repo**, at the hashes in this section and the one above it.

## Does this repo match the two projects? (audit, 2026-09-08)

Every parity number above this section compares the two projects to each other. None of
them compares either project to this repo. This section does that, layer by layer, and
the answer is not uniform.

### Edge functions -- yes, exactly

All 8 byte-identical on both projects and identical to `supabase/functions/`. Hashes in
the sections above.

### `supabase/config.toml` -- was incomplete, now complete

It declared 2 of the 8 functions. Both declarations were correct, but the omission was
not harmless: `verify_jwt` defaults to **true** when a function is not declared, and
four of the six undeclared functions require **false** (`muster-watchdog`,
`muster-backfill-embeddings`, `muster-stripe-webhook`, `muster-ghl-webhook`). A
`supabase functions deploy` of any of those from this repo would have silently locked
out pg_cron, Stripe and GHL, none of which can present a Supabase JWT. All 8 are now
declared, matching live on both projects.

`project_id` stays `mgtmqucaldkaxvxglguw` deliberately. The CLI applies whatever it
finds in `supabase/migrations/` to whichever project it is linked to, and that directory
is the shared project's history -- pointing `project_id` at `hjowfnzpomzxazmzywxw`
without moving the migrations first would push 48 of the wrong project's migrations into
the new one.

### `supabase/migrations/` vs `hjowfnzpomzxazmzywxw` -- yes, all 30

30 files, 30 applied rows, no file without a row, no row without a file, no name
mismatch, and every file byte-identical to its stored statement (17 exact, 13 differing
only by a trailing newline).

### `supabase/migrations-shared-project/` vs `mgtmqucaldkaxvxglguw` -- NO, and by design as much as by accident

The shared project has **656 applied migrations**; this repo carries 48. That part is
expected -- the project is shared across every 28FS brand and this repo holds only
MUSTER's slice. The check that matters is one-directional: does each of the 48 files
match what was applied under its version? Mostly not.

- **47 of 48** have an applied row. One does not: `20260906032839_muster_autotriage_cron.sql`.
- Of the 47, **6 match exactly**, **11 match once a trailing newline is appended**, and
  **30 differ in content**.

The 30 are not corruption. Two causes, both benign, both worth knowing:

1. **Header commentary.** These files carry explanatory headers that were never part of
   the SQL submitted to `apply_migration`. `20260906044502_muster_watchdog_cron.sql` is
   the clean example: file 932 bytes, stored statement 569, and the 363-byte difference
   is a six-line header explaining that the migration was recovered from the ledger. The
   SQL body is byte-identical.
2. **SQL that landed under a different version.** The file is a superset of what its own
   version applied. `20260907022111_muster_agent_retrieval.sql` is 14,266 bytes; the
   statement stored under `20260907022111` is 830 -- the extension, the
   `finding_embeddings` table and its three indexes, and nothing else. The rest
   (`evidence_embeddings`, the search functions, the tool registrations) went in under
   other versions. This is the same failure mode CLAUDE.md already records: filenames
   were not read back from the version `apply_migration` actually assigned.

**The database has the SQL either way.** Spot-checked on the live project:
`muster.evidence_embeddings` exists, both `muster.q_search_*` functions exist, and all
five MUSTER cron jobs are present and active (`muster-alert-dispatch-5min`,
`muster-autotriage-15min`, `muster-embedding-backfill-15min`, `muster-scan-due`,
`muster-watchdog-10min`) -- including the autotriage schedule whose file has no applied
row at all. Nothing is missing from the running system; what is unreliable is the
file-to-version correspondence in this one directory.

Practical consequence: **`supabase/migrations-shared-project/` is a readable history, not a
replayable one.** Do not rebuild a project from it and assume the result matches
`mgtmqucaldkaxvxglguw`. `supabase/migrations/` *is* replayable, and is
what actually built `hjowfnzpomzxazmzywxw`.

### Frontend -- points only at the old project, as expected pre-cutover

`index.html`, `signin.html`, `app.html`, `sitrep.html` and `onboarding.html` all carry
`https://mgtmqucaldkaxvxglguw.supabase.co`. `sitrep-sample.html` carries no Supabase
reference at all, which is right -- it is the static, no-auth sample. This is the
expected pre-cutover state and is already on the outstanding list, not drift.

### Auth email templates -- NOT VERIFIED, and not verifiable from here

`supabase/auth-email-templates/` holds the six GoTrue templates. Supabase Auth config is
not exposed by any tool available in this environment -- there is no read path to the
templates, SMTP settings, Site URL or redirect allowlist that either project is actually
serving. So whether the dashboard matches these six files is **unknown**, on both
projects. `docs/EMAIL.md` already says these have to be pasted in per project and that
auth config does not migrate between projects; that remains a manual check.

Edge function secrets are in the same position: not readable from here, so not verified.

## Cutover step: frontend and config.toml moved to `hjowfnzpomzxazmzywxw` (2026-09-08)

`index.html`, `signin.html`, `app.html`, `sitrep.html` and `onboarding.html` now carry
`https://hjowfnzpomzxazmzywxw.supabase.co` and that project's publishable key
`sb_publishable_VvbvcqDMSTBriHmIMmmvpg_Een-yuWL`. A publishable key is designed to ship
in client HTML; it is not a secret, and it is not the service role key.
`sitrep-sample.html` still carries no Supabase reference, which is correct -- it is the
static, no-auth sample.

`supabase/config.toml`'s `project_id` moved with them, and **the migrations directories
were swapped in the same commit** because `project_id` and `supabase/migrations/` must
name the same project:

| Directory | Holds | Role |
|---|---|---|
| `supabase/migrations/` | 30 files, `hjowfnzpomzxazmzywxw` | the CLI's target, replayable |
| `supabase/migrations-shared-project/` | 48 files, `mgtmqucaldkaxvxglguw` | history, not replayable, do not add to |

Leaving them unswapped would have pointed `supabase db push` at the new project while
handing it the old project's history.

### This is the repo half of cutover. It is not cutover.

Merging this makes the deployed frontend talk to a project that, as of this writing,
**cannot sign anyone in.** Every item below has to be true before the merge is safe, and
none of them is a repo change:

1. **The 3 auth users do not exist on `hjowfnzpomzxazmzywxw`.** Recreate them with their
   existing UUIDs -- `muster.users.auth_user_id` has no FK to `auth.users`, so the rows
   already imported will bind correctly only if the UUIDs match.
2. **GoTrue is unconfigured**: no SMTP, no templates, no Site URL, no redirect
   allowlist. Magic links and password resets will not send, and `signin.html`'s
   `emailRedirectTo` (`window.location.origin + '/app'`) must be on the allowlist or
   GoTrue silently substitutes Site URL. `/reset` needs to be on it too.
3. **Edge function secrets are unset**: `RESEND_API_KEY`, `STRIPE_WEBHOOK_SECRET`,
   `GHL_API_KEY`, `GHL_LOCATION_ID`, and the `muster_ghl_webhook_secret` vault entry.
4. **All five cron jobs are INACTIVE** on the new project, by `muster_028`, deliberately.
   Nothing scans, triages, dispatches alerts or backfills embeddings until they are
   enabled -- and they should be enabled only once the old project's are disabled, or
   both projects will scan and email the same tenants.
5. **The Stripe webhook still points at the old project.**
6. **`public.apply_approved_kb_updates()`** on the shared project writes into
   `muster.jurisdiction_laws`. After cutover it updates a dead schema.

Order matters: 1-3 before the merge, 4-5 at the moment of cutover, 6 whenever the
CORA/JARVIS side is repointed.

## Auth users migrated (2026-09-08)

The three `auth.users` rows and their three `auth.identities` rows are on
`hjowfnzpomzxazmzywxw`, **byte-identical to the source**:

| | md5 on both projects |
|---|---|
| `auth.users` (the 3) | `a2876dbd50c2001eb4e017fc63975aed` |
| `auth.identities` (the 3) | `1ea187cec0977a5313e6f0a923f5c406` |

All three bind to `muster.users` (`select count(*) from muster.users mu join auth.users
au on au.id = mu.auth_user_id` = 3). UUIDs and bcrypt password hashes are preserved, so
**existing passwords work** and nothing needs a reset — which matters, because password
reset is itself blocked until GoTrue is configured.

Method: `auth.users` and `auth.identities` have identical column signatures on both
projects (`a04c75f9f3416057da8ff98da626a3fe` / `3bee18377cd825d2690fe1aaed80efdc`), so a
verbatim row copy is safe. The rows moved server-to-server over `pg_net` through a
token-gated endpoint (`muster_030`, dropped by `muster_031`) rather than as literals in a
statement, because they carry password hashes and that material should not pass through a
transcript, a log, or a migration file. Same reasoning as `muster_023`.

Two things worth knowing for next time:

- `auth.users.confirmed_at` and `auth.identities.email` are `GENERATED ALWAYS`, so
  `insert ... select *` fails. The import reads the column list from `information_schema`
  at call time instead of hardcoding ~35 names.
- `pg_net`'s background worker was stalled and the request sat in
  `net.http_request_queue` unprocessed. `select net.worker_restart();` cleared it. Check
  the queue, not just `net._http_response`, when a pg_net call appears to vanish.

## Grant drift found by diffing advisors, not by reading (2026-09-08)

Comparing `get_advisors` output between the two projects surfaced three divergences that
every previous parity check had missed, all making the new project **more permissive**:

| Object | Old | New (before fix) |
|---|---|---|
| `public.rls_auto_enable()` | postgres, authenticated, service_role | **PUBLIC**, postgres, **anon**, authenticated, service_role |
| `public.cron_error_log` | RLS on + `service_only` policy | RLS on, **no policy** |
| `public.cron_post_log` ACL | postgres, service_role | postgres, **anon**, **authenticated**, service_role |

Fixed by `muster_032`, which asserts the resulting ACLs equal the source's exactly rather
than trusting its own statements. Advisors went 68 → 66 lints, and every remaining lint
has an equivalent on the old project.

**This is the third instance of one root cause.** `muster_021`: Postgres grants EXECUTE
to PUBLIC on every new function, so a fresh project starts more permissive than its
source. `muster_027`: the shim migrations selected on `proname like 'muster%'` and six
RPCs did not carry the prefix. `rls_auto_enable` is both at once — SECURITY DEFINER, from
`muster_002_platform_cron_helpers`, and not named `muster*`, so `muster_021`'s lockdown
never looked at it.

The general lesson, now twice-earned: **a parity check scoped by name only verifies the
set it defined.** The advisor diff worked precisely because it is scoped by behaviour
instead.

## Remaining work

See `docs/CUTOVER.md`. Steps 1 (GoTrue config) and 2 (edge function secrets) are
dashboard-only — no tool in the build environment can read or write Supabase Auth config
or function secrets on either project, so those two are unverifiable from here as well as
unsettable. Everything after them is gated on them.

## Cron swapped to `hjowfnzpomzxazmzywxw` (2026-09-08)

| Project | State |
|---|---|
| `mgtmqucaldkaxvxglguw` | all 5 MUSTER jobs `active=false` |
| `hjowfnzpomzxazmzywxw` | all 5 MUSTER jobs `active=true` |

Old side disabled first, so the two never ran together. `cron.alter_job(jobid, active :=
...)` on both, not `update cron.job set active` — the role has EXECUTE on the function
and no write privilege on the table.

### What was checked first, and why it mattered

The new project's cron jobs were created by `muster_028` from the source project's
definitions, and those definitions **hardcode a project URL in the command body**. An
unchecked flip could have had the new project's scheduler driving the old project's edge
functions.

- Four of five POST to `hjowfnzpomzxazmzywxw...`; the fifth,
  `muster-autotriage-15min`, is `select muster.autotriage();` — in-database, no URL, correct
  by construction.
- `vault.supabase_anon_key` decodes to `ref=hjowfnzpomzxazmzywxw`, `role=anon`. This is
  the one that would have failed silently as a 401 on every HTTP job had the vault entry
  been copied from the old project rather than set from this one's.

### Smoke test before enabling

`muster-watchdog` was invoked through the exact path cron uses — `cron_safe_post` with
both vault secrets — and returned `HTTP 200 {"checks_run":5,"incidents_opened":0}`. One
call proved the vault secrets, `cron_safe_post`, the pg_net worker on this project, the
edge function's `x-muster-secret` check against `muster_engine_secret()`, and the
watchdog RPCs. Watchdog is the right choice for this: read-only, opens incidents only,
never emails.

### Known gap left open deliberately

`muster-alert-dispatch-5min` is enabled while `RESEND_API_KEY` is still unset on this
project. `muster.notification_outbox` is empty, so it has nothing to send and the job is
a no-op until an alert fires. The first critical/high finding on the new project will
queue a row that cannot be delivered until the secret is set — see `docs/CUTOVER.md` §2.

### Rollback expired here

Until this swap, reverting cutover was a `git revert` plus re-enabling the old project's
cron. From the first scan the new project runs, the two databases diverge and reversing
means reconciling data, not flipping a switch.

## Vault secrets completed (2026-09-08)

`muster_ghl_webhook_secret` was in the source project's vault and missing from this one.
`public.muster_ghl_webhook_secret()` reads it by name and `muster-ghl-webhook` compares
it to the `x-muster-secret` header GHL sends, so with the entry absent the function
would have 401'd every request — silently, since GHL's webhook action does not surface
the response.

Copied, not regenerated: the value must match what GHL is already configured to send, so
GHL needs only a URL change at cutover rather than a URL *and* a secret change. Moved
server-to-server over `pg_net` (`muster_033`, dropped by `muster_034`), same reasoning as
`muster_030` — credential material should not appear as a literal in a statement, a
transcript, or a migration file.

| Entry | Verified |
|---|---|
| `muster_cron_secret` | `muster_engine_secret()` resolves it; proven live by the cron smoke test |
| `supabase_anon_key` | decodes to `ref=hjowfnzpomzxazmzywxw`, `role=anon` |
| `muster_ghl_webhook_secret` | md5 `23fdaffd2e7cb37300cd96fa15dd6249` on both projects, and the RPC returns that same value |

The RPC check is the one that matters — matching the vault row proves the copy, but
matching what `muster_ghl_webhook_secret()` *returns* proves the function will actually
authenticate.

## The four edge function secrets are not settable from here

`RESEND_API_KEY`, `STRIPE_WEBHOOK_SECRET`, `GHL_API_KEY`, `GHL_LOCATION_ID` are Deno env
vars on the function runtime, not database objects. No tool in the build environment
reads or writes them, on either project — the same wall as GoTrue config. They are
dashboard work.

`RESEND_API_KEY` should be the existing **`muster-alert-dispatch`** Resend key (created
2026-09-06, already MUSTER-scoped), not a shared one. The shared-credential failure mode
is not hypothetical here: a spend cap on the shared `OPENROUTER_API_KEY`, hit by another
28FS brand, took MUSTER down on 2026-09-06 — the incident is recorded in
`muster-agent/index.ts`. Edge function secrets are project-scoped and this project is
MUSTER's alone, which is why `muster-alert-dispatch` reads plain `RESEND_API_KEY` with no
`MUSTER_*` fallback, unlike the OpenRouter helper.

### The gap is instrumented, not silent

Worth knowing while `RESEND_API_KEY` is unset: `muster-alert-dispatch` resolves each
claimed row as `failed` with `"RESEND_API_KEY is not set"` rather than dropping it.
`muster_engine_watchdog_summary` counts failed outbox rows as `dead_letter_alerts`, and
`muster-watchdog` — running every 10 minutes and verified returning 200 — opens an
`alert_dead_letter` incident when that count is above zero. So the first undeliverable
alert surfaces in the admin console within ten minutes instead of vanishing.

## The watchdog's first real incident was a false positive (2026-09-08)

Six minutes after the cron swap, `muster-watchdog` opened
`cron_missed:muster-autotriage-15min` at severity **critical**. The job then ran
normally at 02:52 and every tick since.

| Time | |
|---|---|
| ~02:44 | all five jobs enabled on this project |
| 02:50:04 | watchdog evaluates; autotriage has no run history here -> `missed` -> critical |
| 02:52:00 | autotriage runs, succeeded |

Incident 2 is closed as `expected_validation` / `not_applicable`, with the full timeline
in its `closure_evidence`. Open incidents: 0.

### The actual check, which is not what its own caller says it is

`muster-watchdog/index.ts` describes this as flagging a job "whose last run is older
than 2x its own schedule interval". The SQL has never done that. It computed:

```sql
missed = (count of successes in the last 30 minutes) = 0
```

A flat window, unrelated to each job's schedule. Both the comment and an earlier
description of this incident in the session were wrong about the mechanism; the code
above is what actually ran.

### `muster_035` -- the fix

`missed` now additionally requires that the job has run at least once at some point, so
a job with no history is treated as not-yet-due rather than missed. Proven by comparing
the old and new expressions side by side, including a synthetic row standing in for a
just-enabled job:

| Job | successes in 30m | ever run | old `missed` | new `missed` |
|---|---|---|---|---|
| *(synthetic: enabled, never run)* | 0 | false | **true** | **false** |
| the five real jobs | 1-5 | true | false | false |

Only the cold-start row changes. `failure_count` is untouched, so a job that fires and
fails still alarms -- and the migration asserts that, along with the function's ACL,
SECURITY DEFINER flag and empty `search_path`, before it will apply.

### Why suppressing "never ran" is not a blind spot

The worry is a job enabled that never fires at all. In pg_cron that case barely exists:
a job that fires and fails still writes a `job_run_details` row, caught by
`failure_count`; a job that writes no row at all was never fired, which means it is
inactive (already filtered) or its schedule was invalid (rejected by `cron.schedule` at
creation). What remains is the cutover case.

### Latent bug found while fixing this -- FIXED by muster_036

**The 30-minute window is a constant, not derived from each job's schedule.** Every
current muster job has a period of 15 minutes or less, so it holds today. Any job
scheduled less often than every 30 minutes would report `missed` permanently, from its
first run onward -- a nightly digest or an hourly sweep would alarm forever.

Fixing it properly means parsing cron expressions to derive each job's period, which is
a materially larger change with its own failure modes. Recorded here rather than
smuggled into a migration about something else. **Anyone adding a muster cron job with a
period over 30 minutes must fix this first.**

### Intended divergence from `mgtmqucaldkaxvxglguw`

`muster_035` is applied to this project only. The old project's copy is unchanged, its
cron is disabled and its watchdog no longer runs, so the drift is inert.
`supabase/migrations-shared-project/` is history and is not added to. This is the fourth
intended difference between the two projects, alongside `muster.do_request_scan`,
`public.muster_create_api_key` and `public.muster_public_pricing`.

## muster_036 -- the missed-window is now schedule-aware

The flat 30-minute window recorded as latent under `muster_035` is gone.
`muster.cron_period_minutes(schedule)` derives each job's period and the threshold is
`greatest(2 * period, 15 minutes)`.

| Job | schedule | period | new threshold | old |
|---|---|---|---|---|
| `muster-alert-dispatch-5min` | `*/5 * * * *` | 5 | **15 min** | 30 |
| `muster-watchdog-10min` | `*/10 * * * *` | 10 | **20 min** | 30 |
| `muster-scan-due` | `*/15 * * * *` | 15 | 30 min | 30 |
| `muster-embedding-backfill-15min` | `*/15 * * * *` | 15 | 30 min | 30 |
| `muster-autotriage-15min` | `7,22,37,52 * * * *` | 15 | 30 min | 30 |

The 15-minute jobs are unchanged. The 5- and 10-minute jobs tighten, which is the point.

Demonstrated both directions on hypothetical schedules:

| Case | since last success | old | new |
|---|---|---|---|
| `0 3 * * *` running normally | 120 min | **alarm** | quiet |
| `@hourly` running normally | 65 min | **alarm** | quiet |
| `30 */6 * * *` running normally | 380 min | **alarm** | quiet |
| `0 3 * * *` genuinely stalled | 3000 min | alarm | **alarm** |
| `@hourly` genuinely stalled | 130 min | alarm | **alarm** |
| `*/5 * * * *` stalled | 16 min | quiet | **alarm** |
| `*/5 * * * *` one late tick | 11 min | quiet | quiet |

The parser returns NULL for anything it cannot derive with certainty -- day-of-week or
day-of-month constraints, ranges, steps inside lists, an hour constraint with anything
but a single minute -- and NULL is treated as not-missed. Guessing a period wrong in the
alarming direction costs trust in every future alert; not alarming costs one unmonitored
job. Such jobs are still monitored for *failures*; `failure_count` is untouched. The
migration asserts that every currently active muster job has a derivable period, so this
cannot silently swallow a real one.

16 parser cases are asserted inside the migration, alongside the ACL, SECURITY DEFINER
and `search_path` checks, and a `revoke ... from public` on the new helper -- Postgres
grants EXECUTE to PUBLIC on every new function, which is why `muster_021`, `muster_022`
and `muster_032` all exist.

Every regex in it uses POSIX classes and bracketed literals rather than backslash
escapes, because `muster_016` and `muster_017` exist entirely because backslashes were
doubled in transcription.

## `apply_approved_kb_updates()` handled (2026-09-08)

The last open cutover item. It turned out to be narrower and more dangerous than the
one-line note it had been carrying.

### What it actually is

JARVIS's approval executor on the **old** project, run every ten minutes by the cron job
`kb-update-executor-10min`, which is still active. It handles two categories:

| Category | Writes to | Owner |
|---|---|---|
| `kb_update` | `public.kb_documents` | CORA/JARVIS |
| `muster_law_update` | `muster.jurisdiction_laws` | MUSTER |

So it is a **shared** function. Retiring it wholesale would have broken JARVIS.

### The real risk was a false success, not a crash

If a `muster_law_update` approval had ever been filed after cutover, the executor would
have updated the decommissioned table, closed the diff, and stamped the approval
`execution_result = {"ok": true}`. An operator reviewing the queue would see a law update
that succeeded and never reached production. A false success in an audit trail is worse
than a visible failure, because nothing ever prompts anyone to look.

### Volume, checked before designing anything

Zero. `muster_law_update`: 0 rows ever. `kb_update`: 0 rows ever. The 235 rows in
`jarvis_approvals` are `content`, plus small counts of `comms`, `compliance_review`,
`agents`, `rnd_prototype`, `Testing`, `User Management`. Both branches of this executor
are dormant, which is why this is a latent trap being closed rather than a live
integration being cut.

### The change

Only the `muster_law_update` branch. It now marks the approval terminally with
`ok:false` and a reason naming the new project, and `continue`s -- per-row, so one
refused MUSTER approval can never block JARVIS's own work in the same pass. The
`kb_update` and `company_id` branches are byte-identical, the rejected-diff sweep is
untouched, and the cron job keeps running. `search_path` drops `muster`, so the schema is
no longer even resolvable from the function.

### Proven behaviourally, then rolled back

A synthetic `muster_law_update` approval was inserted, the executor run, and the outcome
asserted inside a transaction that then deliberately aborted, so nothing persisted
(verified: 0 rows remain):

| Assertion | Result |
|---|---|
| return value (applied count) | `0` -- refused rows are not counted as applied |
| `executed_at` set | yes -- terminal, so it does not retry every 10 minutes forever |
| `ok` flag | `false` -- no false success |
| reason recorded | names `hjowfnzpomzxazmzywxw` and what to do |
| law row unchanged | **yes** -- the decommissioned table was not written |

### The wider audit this prompted

Checking the fix surfaced 73 functions in `public` on the old project that reference
`muster.*`. Broken down:

- **66** are MUSTER's own `muster_*` shims. Expected, dormant, no cron callers.
- **6** are MUSTER's own unprefixed RPCs -- `get`/`count`/`insert` for finding and
  evidence embeddings. These are the same six whose missing prefix defeated the shim
  migrations' `proname like 'muster%'` filter and required `muster_027`. No cron callers.
- **1** was `apply_approved_kb_updates` -- the only function belonging to another product
  that reached into MUSTER's schema, and the only one of the 73 with a live scheduler.

So the cross-product coupling was exactly one function, and it is now closed.

### Left open deliberately, because it is a product decision

Whether JARVIS should be able to propose MUSTER law updates at all, now that MUSTER is a
separate product on a separate project. Zero such approvals have ever been filed, so
there is no demonstrated need. If the answer is yes, it needs an explicit cross-project
path on `hjowfnzpomzxazmzywxw` -- not a resurrection of this branch.

## 2026-09-08 -- STRIPE_WEBHOOK_SECRET set on hjowfnzpomzxazmzywxw

Set in the dashboard (Edge Functions -> Secrets); no tool or network route exists from
here for edge function secrets, so this was the one step that had to be done by hand.

Verified live, without ever handling the secret value, by probing the deployed function
with an unsigned body over `pg_net`:

```sql
select net.http_post(
  url := 'https://hjowfnzpomzxazmzywxw.supabase.co/functions/v1/muster-stripe-webhook',
  headers := jsonb_build_object('Content-Type','application/json'),
  body := jsonb_build_object('probe', true),
  timeout_milliseconds := 20000);
-- then: select status_code, content from net._http_response where id = <returned id>;
```

The two outcomes are unambiguous, which is what makes this probe worth keeping:

| Response | Meaning |
|---|---|
| `500 {"error":"STRIPE_WEBHOOK_SECRET is not set"}` | secret absent (or named wrong) |
| `401 {"error":"invalid signature"}` | secret present, HMAC failing closed on an unsigned body -- **correct** |

Probes 51, 53, 56 returned 500. Probe 63 (04:26:01Z) returned 401. Secret is in.

Note the probe proves the secret *exists*, not that it *matches* the Stripe endpoint --
a wrong `whsec_` fails identically at 401. Only a real Stripe-signed delivery separates
those two, which is the next step.

### Baseline captured before the first live delivery

`muster.pending_commercial_grants` = 0 rows, `max(created_at)` null. Any row appearing
after a Stripe test send is attributable to that send.

### Still outstanding on this project

- Stripe Payment Link metadata: `tier` + `stage`, one of the four pairs in
  `muster.commercial_pricing` (`muster`/`seed`, `muster`/`fruit`, `muster_partner`/`seed`,
  `muster_partner`/`fruit`). `muster_enterprise` is **not** a valid pair -- that tier is
  sales-assisted through GHL. Mode must be `subscription` and the link must collect email.
- `GHL_API_KEY` and `GHL_LOCATION_ID` edge secrets.
- GoTrue email rate limit still at the built-in default (~2/hour) despite custom SMTP.
- Sitrep redirect allowlist click-test against the 11-entry list.

## 2026-09-08 -- muster-agent redeployed to both projects (ai_narrative hardening)

Prompted by building `evals/ai-narrative`. The eval work surfaced a fail-open in
`ai_narrative` and required splitting the tool's pure half into
`muster-agent/narrative.ts`, so both projects were redeployed to keep the
byte-identity invariant.

### The defect

`verifyNarrativeCitations` checked only the `citations` array the model declared.
A model that wrote an invented `F8888` into a board-facing sentence and left it
out of that array returned `confidence: "high"` with an empty
`unverified_citations`. The tool advertises to agents that "the model never sees
or invents anything outside" the supplied data; that path did not enforce it.

Verification now scans the narrative prose as well and folds both sources through
the same allowed-set test. A fabricated id always lands in `unverified_citations`
and always forces `confidence` to `"low"`.

`ai_narrative` was **not** dormant when this was found: `default_enabled` true,
`kill_switch` false, `plan_minimum` pro, zero overrides. The fail-open was
reachable.

### Deploy

| | |
|---|---|
| `hjowfnzpomzxazmzywxw` | version 6 |
| `mgtmqucaldkaxvxglguw` | version 14 |
| `ezbr_sha256` (both) | `ec23b1c99619777a91e6a9ff6dc13e4b0aa1a6d08243e2847c8c3391514e1e42` |

Identical hashes are the cross-project check: the same three files
(`index.ts`, `prompt.ts`, `narrative.ts`) reached both. Smoke-tested live on both
after deploy -- `GET /muster-agent` returns 200 with 14 tools and the correct
`endpoint`, and on the new project `GET /muster-agent/openapi.json` returns 200
with `x-muster.toolCount` 14. That is what proves the new `./narrative.ts` import
resolves in the Deno runtime.

### Note for whoever reads this next

Nothing in the frontend renders `unverified_citations`. The forced `confidence`
downgrade is currently the only signal that a fabrication reached a reader. If a
surface starts displaying narratives, show that field.

The `--profile`-style static scanners will keep scoring this repo's tool surface
low: MUSTER's tool schemas live in `muster.agent_tools`-shaped SQL read through
`muster_engine_agent_tools()`, and the OpenAPI document is generated per request
by `generateOpenAPISchema`. Neither is a file to grep. That is a property of the
architecture, not a gap.

## 2026-09-08 -- Resend delivery tracking, suppression, and a magic-link signup hole

### Inspection first: what already existed

MUSTER was not missing an email system. Two paths, both already through Resend, both already
documented in `docs/EMAIL.md`:

- **Path A, auth email.** GoTrue renders and sends magic link, invite, signup confirm, email change,
  password reset and reauthentication, reaching Resend only because Resend is its SMTP relay. Six
  branded templates already in `supabase/auth-email-templates/`.
- **Path B, application email.** `muster-alert-dispatch` drains `muster.notification_outbox` through
  the Resend REST API with an idempotency key, multipart HTML + text, a unique dedupe index on
  `(entity_type, entity_id, category)`, and a 5-attempt retry policy owned by
  `muster_engine_resolve_alert`.

`mail.muster.partners` is verified, sending enabled, and **click tracking is already off** -- which
is what keeps a link scanner from rewriting an authentication URL. Nothing to change there.

So the work was gaps, not a rebuild. Building a second sender would have produced duplicate mail.

### Gap 1: nothing distinguished accepted from delivered

`muster-alert-dispatch` called a row `sent` on a 2xx from `POST /emails`. Resend accepts, queues,
and may bounce minutes later. The proof, captured live during this work:

| | |
|---|---|
| Resend's own record for `c23a0198-…` | `Status: delivered` |
| MUSTER's outbox for the same message | `delivery_status: accepted`, `delivered_at: null` |

MUSTER had no way to close that gap because it never stored the id Resend returned.

`muster_037` adds `muster.email_events`, `muster.email_suppressions`, and
`provider_message_id` / `delivery_status` / `delivered_at` / `last_event_at` on the outbox.
`delivery_status` is deliberately a **separate column** from `status`: `status` is the outbox's own
work state, `delivery_status` is what the provider reported. A send response can only ever produce
`accepted`.

`muster-resend-webhook` (new) verifies the Svix signature over the raw body and records events.
Statuses are rank-guarded so a late `email.sent` cannot overwrite a `delivered` and a bounce
outranks everything; the Svix message id is a unique key so a redelivery inserts nothing.

### Gap 2: bounced addresses were mailed forever

A hard bounce now writes to `muster.email_suppressions`. `muster_engine_claim_alerts` was rewritten
(from `language sql` to plpgsql) to drop suppressed addresses from the recipient list, and to
terminate a row whose recipients are *all* suppressed as `skipped` with the reason recorded, rather
than sending it into a wall. Stored `recipient_emails` are left intact, so lifting a suppression
restores delivery with no backfill. Transient bounces are recorded but never suppress.

### Gap 3: the sign-in form was an open signup path

`signin.html` called `signInWithOtp` without `shouldCreateUser`. It defaults to **true**. Self-serve
signup is paused and new accounts are meant to route through sales, so the magic-link form was
quietly creating an account for any address typed into it -- and, because a new address behaved
differently from an existing one, it was also an enumeration oracle.

Now `shouldCreateUser: false`, with both link types behind one `requestLink()` that returns the same
neutral confirmation on every outcome including a 429, plus a 60-second resend cooldown so the user
sees a countdown instead of an error they cannot act on. The client cooldown does not replace
GoTrue's server-side limit and is not a security control.

### Deliberate divergence between the two projects

`muster_037` and the new function are on `hjowfnzpomzxazmzywxw` **only**, and the modified
`muster-alert-dispatch` was deployed there only. The old shared project has all five `muster-*` cron
jobs inactive (verified), so its dispatcher is never invoked; handing it the new four-argument
`resolve_alert` call against a schema with no `muster_037` would break it for no benefit. This is the
first intentional break in the byte-identity rule, and it is safe only because the old side is dark.

### What the send-response id buys, concretely

An operator can now answer "did the tenant actually get the critical alert" from
`notification_outbox.delivery_status` joined to `muster.email_events`. Before this the honest answer
was "Resend accepted it", and that was all anyone could ever say.

### Still outstanding (dashboard, cannot be done from here)

- `RESEND_WEBHOOK_SECRET` on `hjowfnzpomzxazmzywxw`. Until it is set the function answers 500 and
  refuses every event rather than trusting an unsigned one. Alert *sending* is unaffected.
- The Resend webhook endpoint itself. Not created from here on purpose: it would have started
  delivering into a function guaranteed to 500 until the secret exists, and repeated 5xx is how an
  endpoint gets auto-disabled.
