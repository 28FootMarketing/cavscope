# `hjowfnzpomzxazmzywxw` migration ledger

`supabase/migrations/*.sql` in this directory is the ledger for the **old shared**
project `mgtmqucaldkaxvxglguw`. MUSTER's own dedicated project is
`hjowfnzpomzxazmzywxw`, and its migrations are **not** in this directory yet.

That is a known, recorded gap, not an oversight. It is the same failure mode PR #46
fixed for the other project, so it does not get to happen quietly twice.

## Applied to `hjowfnzpomzxazmzywxw` so far

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

## Why the files are not here yet

These were generated from the **live catalog** of `mgtmqucaldkaxvxglguw`, not replayed
from this directory, because 24 of 39 files here differ from what was actually applied
and the drift is concentrated in function bodies. The SQL exists in
`supabase_migrations.schema_migrations.statements` on the target project; the files get
written from there in one dedicated pass before cutover, so they are transcribed once
rather than twice.

**Cutover is not complete until they land here.** Once `mgtmqucaldkaxvxglguw` is
decommissioned, its catalog stops being a source of truth and this ledger is all
that is left.

## Verified state (2026-09-07)

Structure and functions are at parity with source, by checksum, not by inspection:

- 45 tables, 490 columns, 45 PKs, 12 uniques, 79 checks, 91 FKs, 122 indexes
- 58 of 58 `muster.*` functions. `md5` over all of them except `do_request_scan`,
  ordered by name and identity args, is `93d046b0e446fb63a595a3e46c12742e` on **both**
  projects.
- `do_request_scan` is the one intended difference: it hardcodes the Supabase URL it
  POSTs to in order to kick the scan engine, and on this project that URL points here.
  Copied verbatim it would have queued scans on the new project and executed them on
  the old one.

## Still missing on `hjowfnzpomzxazmzywxw`

- 70 `public.muster_*` RPC shims. **Nothing can reach the database without these** --
  the `muster` schema is not exposed to PostgREST, so the shims are the only door.
- RLS on 29 of 45 tables; 63 of 79 policies; 13 of 25 triggers
- Policy naming: source calls the catch-all `sentinel_app_all`, the baseline here
  created `muster_app_all`
- 730 rows and ~13 MB of embeddings
- 8 edge functions (7 have source in this repo; `muster-verify-site` does not)
- 5 cron jobs, with URLs rewritten to this project
- Vault secrets, the `jarvis_signals` sink decision, and the 3 auth users
  (password hashes do not migrate)
- Frontend `SB_URL`/`SB_KEY` in `index.html`, `signin.html`, `app.html`, `sitrep.html`,
  `onboarding.html`
- Supabase Auth config: SMTP, the six templates, Site URL, redirect allowlist
  (see `docs/EMAIL.md`) -- none of it migrates between projects
