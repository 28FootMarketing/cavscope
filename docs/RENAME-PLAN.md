# Backend rename: `muster_*` / `muster-*` to `cavscope_*` / `cavscope-*`

Status, read from the live project 2026-10-01: **stage 1 is applied** (migration
`20260930225424`, `rpc_rename_cavscope`: 117 `public.cavscope_*` functions and 109 `muster_*`
aliases forwarding to them; grants, argument names and return types verified identical on all 109
pairs). **Stage 2 is done and live**: pages, edge functions, tools and tests call the `cavscope_*`
names (PR #182, merged and deployed 2026-10-01); both names still answer.
**Stage 3 is done and live** (2026-10-01): half A (directories, config, in-function references) is PR
#183, and half B (pages, `AGENTS.md`, the MCP server card, the 4 cron jobs and the 3 database call
sites, migration `20261001193032`) followed once all 17 new slugs answered like their old twins.
**The external webhooks (Stripe, GHL, Resend, Telegram) still deliver to the old frozen
`muster-*` slugs until stage 4**, so a change to a webhook function does not reach its live traffic
until that webhook is repointed. Stage 5 has not started.
**Stage 5's evidence is the API gateway log, not `pg_stat_statements`** (corrected 2026-10-09).
The first two snapshots used `pg_stat_statements` counts per `muster_*` name, and on 2026-10-09
every count had grown all week, which read as "still called". None of it was. The rename kept each
function's OID (`cavscope_engine_secret` is oid 19354, the original; the `muster_engine_secret`
alias is a new wrapper), and `pg_stat_statements` keys on the OID and keeps the query text it saw
first, so every call to a `cavscope_*` name is counted on the row that still reads `muster_*`. There
is no `cavscope_engine_secret` row at all, against 2,475 gateway calls to it in one day. That check
can never go quiet and must not be used. `docs/rename/calls-since-baseline.sql` now carries the
log query instead; `track_functions` stays unsettable from the MCP role and is still not needed.
Target project `hjowfnzpomzxazmzywxw`.
The `muster` schema was already renamed to `cavscope` (54 tables, 82 functions); what still
carries the old name is the callable surface below.

## What carries the name (read from the live project, 2026-09-30)

| Surface | Count | Notes |
|---|---|---|
| `public.muster_*` RPCs | 112 | 109 renameable, 3 triggers stay. No overloads, all args named, all `SECURITY DEFINER`, 4 set-returning, 8 executable by `anon`. |
| RPCs the pages and edge functions call by name | 69 | `app.html`, `admin.html`, `signin.html`, `sitrep.html`, `onboarding.html`, `index.html`, edge functions, `tools/`. |
| Edge functions | 18 | All `muster-*`. |
| pg_cron jobs posting to function URLs | 4 | `muster-alert-dispatch-5min`, `muster-embedding-backfill-15min`, `muster-scan-due`, `muster-watchdog-10min`. |
| DB code calling an edge function by URL | 3 | `cavscope.do_request_scan` (`muster-scan`), `public.muster_create_api_key` (`muster-agent`), `public.muster_notify_beta_signup` (`muster-beta-notify`). |
| External callers of function URLs | outside this repo | Stripe, GoHighLevel, Resend and Telegram webhooks. Only their owners' dashboards can repoint them. |
| API contract | | `x-muster-api-key` header, `mk_` key prefix, `muster-agent` path in `AGENTS.md` and `.well-known/mcp/server-card.json`. |

## Order matters

The pages deploy from `main` the moment a PR merges, so **a page that calls `cavscope_*`
must not merge before the database has those names**. Hence the stages:

1. **Database (this PR ships the SQL, unapplied).** `docs/rename/001_rpc_rename.sql`
   renames the 109 functions and leaves an identical-grants `muster_*` alias for each. All
   or nothing in one transaction. Run `docs/rename/verify.sql` after; every row must be
   `ok = true`. Nothing breaks, because every old name still answers.
2. **Callers.** Switch pages, edge functions and tests to `cavscope_*`. Only after stage 1
   is applied and verified.
3. **Edge functions, in two halves.** Renaming a directory moves code that tests and
   `tools/local-scan/` read by path, so those paths change in the same PR, and
   `supabase/config.toml` carries per-function `verify_jwt` settings that **must move with the
   directory**: a renamed function with no matching entry deploys with the default and rejects
   every Stripe, Resend and GHL webhook with 401.
   - **Half A (this branch):** move the 17 `muster-*` directories to `cavscope-*`, rename their
     `config.toml` sections (`verify_jwt` and `entrypoint` otherwise identical, checked by
     script), and the references inside functions, tools and tests. On merge CI deploys 17 new
     slugs **alongside** the old ones, which stay deployed, frozen at their last version (CI
     deploys what is in the tree and the CLI does not delete). Pages, `AGENTS.md` and the public
     MCP server card still name the old slugs, deliberately: pages deploy the instant a PR merges
     but functions deploy about a minute later, so switching a page in the same merge opens a
     window where it calls a function that does not exist yet.
   - **Half B (done 2026-10-01; kept as the record of what it covered):** switch the pages, `AGENTS.md`
     and `.well-known/mcp/server-card.json` to the new slugs; repoint the 4 cron jobs and the 3
     database call sites (`cavscope.do_request_scan`, `public.cavscope_create_api_key`,
     `public.muster_notify_beta_signup`). Until then scans and webhooks keep using the frozen old
     functions, so an engine change merged in the meantime reaches only the new slugs: do half B
     promptly.
4. **External callbacks.** Repoint the Stripe, GHL, Resend and Telegram webhooks at the new
   URLs. Until each one is confirmed delivering, its old function stays deployed.
5. **Retire.** Drop the `muster_*` aliases and delete the old functions, once nothing calls the old
   names for a full week. Evidence is the API gateway log, read one 24-hour window at a time with
   the query in `docs/rename/calls-since-baseline.sql`: `edge_logs` rows whose path is
   `/rest/v1/rpc/muster_*` (the RPC aliases) and `function_edge_logs` rows whose pathname is
   `/functions/v1/muster-*` (the frozen old slugs). The two CSV snapshots and the clock they set
   are void; see the status paragraph at the top for why `pg_stat_statements` cannot answer this.
   **The log sweep on 2026-10-09 covered every window from 2026-10-02 12:00 UTC** and found: the last
   call to an old RPC name at 2026-10-03 03:21 UTC (three workspace reads from an iPad browser, a
   cached pre-rename page); the last request to an old slug at 2026-10-03 23:47 UTC (a `python-httpx`
   probe from a Helsinki cloud host against `muster-agent`: `/v1/models` answered 200, four
   `/v1/chat/completions` answered 401, no customer); nothing since. **The quiet week therefore runs
   from 2026-10-03 23:47 UTC and the earliest stage 5 date is 2026-10-11**, provided stage 4 is done
   first: the Resend webhooks already deliver to `cavscope-*` (read from Resend 2026-10-09), but the
   Stripe, GHL and Telegram endpoints cannot be read from this repo's tooling and must be confirmed
   by their owner. Re-run the sweep for the windows after 2026-10-09 12:00 UTC before retiring; a hit
   restarts the clock. Deleting the old edge functions needs the Supabase CLI: the MCP has no delete
   for them.

## Deliberately not in the first pass

- `x-muster-api-key` and the `mk_` prefix. Live customers' integrations send them. If they
  change, accept both headers for a deprecation period rather than swapping one.
- The `muster.partners` and `*.muster.28footsystems.com` hosts. Magic-link and invite emails
  already delivered point at them.
- `support@` and `security@` on `mail.muster.partners`. Move them only after the inbox on the
  CavScope mail domain is confirmed monitored; a lost vulnerability report costs more than a
  stale name.

## Why aliases are `SECURITY INVOKER`

An alias that ran with its owner's rights would be a second door into a `SECURITY DEFINER`
function, with its own grants to keep in sync. Running as the caller means the real function
and its grants decide, and a grant can never be wider on the alias than on the function.
Grants are copied explicitly because Supabase hands every new public function to `anon` and
`authenticated` by default (see the `muster_engine_*` note in `CLAUDE.md`).
