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

## Still missing on `hjowfnzpomzxazmzywxw`

- 730 rows and ~13 MB of embeddings
- 8 edge functions (7 have source in this repo; `muster-verify-site` does not)
- 5 cron jobs, with URLs rewritten to this project
- Vault secrets (`muster_cron_secret`, `supabase_anon_key`, `muster_ghl_webhook_secret`),
  the `jarvis_signals` sink decision, and the 3 auth users (password hashes do not migrate)
- Frontend `SB_URL`/`SB_KEY` in `index.html`, `signin.html`, `app.html`, `sitrep.html`,
  `onboarding.html`
- Supabase Auth config: SMTP, the six templates, Site URL, redirect allowlist (see
  `docs/EMAIL.md`). None of it migrates between projects.
- Stripe webhook repoint
- The migration files themselves, per above
