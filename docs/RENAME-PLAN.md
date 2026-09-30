# Backend rename: `muster_*` / `muster-*` to `cavscope_*` / `cavscope-*`

Status: **proposed, nothing here has been applied.** Target project `hjowfnzpomzxazmzywxw`.
The `muster` schema was already renamed to `cavscope` (54 tables, 82 functions); what still
carries the old name is the callable surface below. `CLAUDE.md` still says the `muster`
schema is live, which is stale.

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
3. **Edge functions.** Rename each directory to `cavscope-*` and deploy them **alongside**
   the old ones (CI deploys what is in the tree, so the old ones are removed from the tree
   only in stage 5). Repoint the 4 cron jobs and the 3 DB call sites.
4. **External callbacks.** Repoint the Stripe, GHL, Resend and Telegram webhooks at the new
   URLs. Until each one is confirmed delivering, its old function stays deployed.
5. **Retire.** Drop the `muster_*` aliases and delete the old functions, once function logs
   and `pg_stat_user_functions` show no calls to the old names for a full week.

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
