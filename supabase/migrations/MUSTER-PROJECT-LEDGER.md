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

## Why the files are not here yet

Generated from the **live catalog** of `mgtmqucaldkaxvxglguw`, not replayed from this
directory, because 24 of 39 files here differ from what was actually applied and the
drift is concentrated in function bodies. The SQL is in
`supabase_migrations.schema_migrations.statements` on the target; the files get written
from there in one pass before cutover, so it is transcribed once rather than twice.

**Cutover is not complete until they land here.** Once `mgtmqucaldkaxvxglguw` is
decommissioned its catalog stops being a source of truth and this ledger is all that is
left.

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
- **The migration files themselves.** This directory is still the old project's ledger.

## Two stale hostnames, deliberately left alone

Both were copied forward byte-identically to keep the parity checksums meaningful, and
both should be fixed on BOTH projects in one change so they cannot drift apart again:

- `muster.autotriage()` puts `https://app.muster.28footsystems.com/` in the alert body.
- `muster-scan`'s User-Agent advertises `+https://muster.28footsystems.com/scanner` to
  every site it scans.

The product's home is `muster.partners` now. The old hosts still resolve, so neither is
broken -- just wrong.
