# `supabase/migrations-shared-project/` — MUSTER's slice of `mgtmqucaldkaxvxglguw`

**History, not the CLI's target.** These 48 files are the MUSTER migrations applied to
the old shared 28FS project. `supabase/config.toml` now points at
`hjowfnzpomzxazmzywxw`, whose migrations live in `supabase/migrations/`. Nothing here is
replayed by `supabase db push` any more, and nothing here should be added to.

Treat it as a **readable history, not a replayable one**: 30 of these 48 files differ in
content from the statement actually applied under their version (header commentary in
some, SQL that landed under a different version in others), and one has no applied row
at all. The running database has the SQL either way — see
`supabase/migrations/MUSTER-PROJECT-LEDGER.md` for the audit. Do not rebuild a project
from this directory and assume the result matches.

Every file here is named `<version>_<name>.sql`, where `<version>` is the
**exact `version` recorded in `supabase_migrations.schema_migrations`** on
project `mgtmqucaldkaxvxglguw`. That is the whole rule, and it exists because
breaking it broke the directory once already.

## Why the filenames are what they are

Migrations here are applied through the Supabase MCP `apply_migration` tool,
which **assigns the version itself at apply time from the wall clock**. It does
not read the filename. So a file called `20260908070000_...` could be, and was,
applied as version `20260906072119`.

That divergence is invisible until you try to use the directory for anything:

- **Ordering.** Filename timestamps drifted up to two days ahead of the versions
  actually assigned. Sorted by filename, `20260907053101` (which calls
  `muster.evidence_embeddings`) came *before* `20260907210000`, which creates it.
  A rebuild from empty failed. There were **16 such forward references** across
  the directory on 2026-09-07 — the schema in this repo could not be replayed.
- **Identity.** With filenames and versions disagreeing, there was no mechanical
  way to tell which applied migrations had a file and which did not. Four did
  not (below).

Naming files after their applied version fixes both at once: the directory sorts
in true application order, and a file is present exactly when its version is.

## Files that consolidate more than one applied version

Several features were applied incrementally while being iterated on, then
written up as one clean file. Those files take the version of the **first**
migration they consolidate — the point where their objects came into existence,
so anything depending on them still sorts later.

| File | Also carries |
|---|---|
| `20260906005205_add_ai_governance_category.sql` | `20260906032608` `add_ai_governance_category_retro` |
| `20260906012143_muster_onboarding_pipeline.sql` | `20260906032621` `muster_onboarding_pipeline_retro` |
| `20260906032658_muster_critical_finding_alerts.sql` | `20260906032749` `muster_alert_resolve_retry_fix` |
| `20260906044320_muster_incidents_watchdog.sql` | `20260906044433` `muster_watchdog_backing_rpcs` |
| `20260906062134_muster_admin_url_runner.sql` | `20260906062220` `muster_admin_url_runner_fix_trigger` |
| `20260906072119_muster_onboard_client_fixes.sql` | `20260906072206`, `20260906072236`, `20260906072300`, `20260906072450` |
| `20260907022111_muster_agent_retrieval.sql` | `20260907022115`, `022119`, `022126`, `022148`, `022200` |

## Applied migrations that had no file at all

Recovered on 2026-09-07 from `supabase_migrations.schema_migrations.statements`:

- `20260906032838_muster_alert_dispatch_cron.sql`
- `20260906044502_muster_watchdog_cron.sql`
- `20260906044516_muster_admin_overview_add_incidents.sql`

Their absence was not cosmetic. Without the first two, a rebuild produced the
alert and incident tables, the RPCs, and the edge functions, and then **never
scheduled anything to call them**. Without the third, the super admin console
had no `incidents` key and could not display a single incident.

## A job with no provenance anywhere

`20260906032839_muster_autotriage_cron.sql` is **not** recovered — it is
reconstructed from `cron.job`. `muster-autotriage-15min` has been running live
since 2026-09-06, but no row in `schema_migrations` mentions it: it was
scheduled by hand, outside `apply_migration`, so the ledger never saw it either.
Its version is a placement one second after the migration that creates
`muster.autotriage()`, not a real applied version. It is the only file here
whose version is invented, and it is labelled as such in its own header.

## Deliberately absent

| Version | Name | Why |
|---|---|---|
| `20260903095155` | `rename_sentinel_schema_to_muster` | `alter schema sentinel rename to muster` |
| `20260903095157` | `rename_sentinel_app_role_to_muster_app` | `alter role sentinel_app rename to muster_app` |

Both predate this repo and rename objects that no file here creates.
`20260904034922_muster_phase1_scan_engine.sql` builds the `muster` schema
directly, so replaying these on a fresh project would fail on a missing
`sentinel`. They are recorded here rather than shipped.

## Checks worth re-running

```sql
-- 1. Every file has a matching applied version, and vice versa.
select version, name from supabase_migrations.schema_migrations
where version >= '20260904034922' and name ilike '%muster%' order by version;

-- 2. Every live muster cron job is reproducible from this directory.
select jobname, schedule, active from cron.job where jobname ilike '%muster%';
```

Then `grep -l "'<jobname>'" *.sql` for each job. As of 2026-09-07 all five
(`muster-scan-due`, `muster-autotriage-15min`, `muster-alert-dispatch-5min`,
`muster-watchdog-10min`, `muster-embedding-backfill-15min`) resolve to a file.

**When you apply a migration through `apply_migration`, read back the version it
assigned and name the file that.** Do not name the file first and hope.
