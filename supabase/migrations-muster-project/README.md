# `hjowfnzpomzxazmzywxw` — MUSTER's dedicated Supabase project

These 30 files are the complete build history of MUSTER's own project, exported from
that project's `supabase_migrations.schema_migrations` ledger. **Every file's content
is byte-identical to the statement Postgres recorded as actually applied** — they are
not a reconstruction from memory or from the catalog.

Exactly: 17 of the 30 files md5-match the stored statement outright; the other 13 match
once a single trailing newline is appended, because those files end with a newline and
the submitted statement did not. A trailing newline after the final `;` changes nothing
semantically, but the distinction is recorded here rather than rounded off, because an
earlier version of this note claimed a plain md5 match for all 30 and that was not
true.

## Why this is a separate directory

`supabase/migrations/` is the ledger for the **old shared** project
`mgtmqucaldkaxvxglguw`, and it stays that way until that project is decommissioned.
Merging the two would be actively dangerous: `supabase db push` applies whatever it
finds in `supabase/migrations/` to whichever project the CLI is linked to, so one
directory holding two projects' histories is a loaded gun.

At decommission, archive `supabase/migrations/` and rename this directory to
`migrations/`. Not before.

## The naming rule still applies

Filenames here are `<version>_<name>.sql` where `<version>` is the version
`apply_migration` assigned from its own clock — read back from the ledger, not guessed
from when the SQL was written. That is the same rule `supabase/migrations/README.md`
sets out, and it is the rule whose violation created 16 forward references and four
applied-but-fileless migrations on the old project.

## Reading order, and what each group does

| Files | What |
|---|---|
| `000`–`002` | extensions, `vector` relocated into `public` to match source, cron helpers |
| `003`–`011` | the 45 tables, keys, checks, foreign keys, indexes, and two drift passes |
| `012` | 22 SQL helper functions (the authorization spine) |
| `013`–`018` | the remaining 36 `muster.*` functions, plus three transcription repairs |
| `019`–`022` | RLS, 79 policies, 25 triggers, all 70 `public.muster_*` shims, EXECUTE grants |
| `023`–`026` | the temporary data-import endpoint, its use, and its removal |
| `027` | the six embedding RPCs the shim migrations' name filter had missed |
| `028` | the five cron schedules, created inactive |

## Three files worth reading before you touch this project again

- **`muster_021` + `muster_022`** together explain why grants do not come along for
  free in either direction. Postgres grants EXECUTE to PUBLIC on every new function, so
  a fresh project starts *more* permissive than its source; and the blanket revoke that
  fixes that takes `service_role` with it wherever `service_role` only held access
  through PUBLIC. Both were caught by comparing ACL checksums, not by reading.
- **`muster_024`** is the one that proves counting is not verifying. The earlier
  structural check compared object *counts* — 79 checks, 122 indexes — and passed, while
  `users_role_check` was silently missing `super_admin` and rejected the admin row on
  import.
- **`muster_027`** is the same lesson from the other side: the "70/70 shims" checksum
  was true and useless simultaneously, because it verified the set it had defined
  (`proname like 'muster%'`) rather than the set the system needs.

## One dead credential is recorded here on purpose

`muster_023` contains the literal token that gated the temporary bulk-import endpoint.
That endpoint was dropped by `muster_026` and the token grants nothing on any system.
It is left in place because this directory is a history, and editing history to look
tidier is how a ledger stops being trustworthy. Do not reuse the value.
