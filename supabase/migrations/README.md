# `supabase/migrations/` — `hjowfnzpomzxazmzywxw`, MUSTER's own Supabase project

**This is the directory `supabase/config.toml` points at.** `project_id` is
`hjowfnzpomzxazmzywxw`, and these are that project's migrations, so the CLI's target and
this directory agree. They must stay in agreement: the moment they disagree,
`supabase db push` applies one project's history to a different project.

These 37 files are the complete build history of MUSTER's own project, exported from
that project's `supabase_migrations.schema_migrations` ledger. **Every file's content
is byte-identical to the statement Postgres recorded as actually applied** — they are
not a reconstruction from memory or from the catalog.

Exactly: 24 of the 37 files md5-match the stored statement outright; the other 13 match
once a single trailing newline is appended, because those files end with a newline and
the submitted statement did not. A trailing newline after the final `;` changes nothing
semantically, but the distinction is recorded here rather than rounded off, because an
earlier version of this note claimed a plain md5 match for all 30 and that was not
true.

## Why the old project's history is in a different directory

`supabase/migrations-shared-project/` holds the 48 MUSTER migrations that were applied
to the **old shared** project `mgtmqucaldkaxvxglguw`. It is kept as history and is not
the CLI's target any more.

Merging the two would be actively dangerous: `supabase db push` applies whatever it
finds in `supabase/migrations/` to whichever project the CLI is linked to, so one
directory holding two projects' histories is a loaded gun. Keep them apart.

These directories were swapped when `config.toml`'s `project_id` moved to
`hjowfnzpomzxazmzywxw`, because `project_id` and this directory have to name the same
project or the footgun above is armed. An earlier version of this note said to do the
swap "at decommission" — that assumed `project_id` would move at decommission too. It
moved first, so the swap came with it.

## The naming rule still applies

Filenames here are `<version>_<name>.sql` where `<version>` is the version
`apply_migration` assigned from its own clock — read back from the ledger, not guessed
from when the SQL was written. That is the same rule
`supabase/migrations-shared-project/README.md` sets out, and it is the rule whose
violation created 16 forward references and four applied-but-fileless migrations on the
old project. That directory is a readable history but **not a replayable one**; this one
is both.

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
| `029` | the autotriage alert URL moved to `app.muster.partners/app` |
| `030`–`031` | the temporary auth.users import endpoint, its use, and its removal |
| `032` | grants reconciled to source after an advisor diff caught three divergences |
| `033`–`034` | the temporary vault-secret import endpoint, its use, and its removal |
| `035` | cold-start guard on the cron health check, after it opened a false critical at cutover |
| `036` | the missed-window becomes schedule-aware; kills the flat 30-minute constant |

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

## Post-apply verification notes go here, not into the migration file

A migration file in this directory is a verbatim record of the statement Postgres
recorded. Anything learned *after* applying — a verification run, a caveat, a thing
that turned out to matter — cannot go into the file without breaking that, because the
file would then say it is the applied statement while no longer being it. It goes in
this README instead, under the version it belongs to.

This rule is written down because it was broken immediately. `20260915230805`
(`muster_052`) carried eleven appended comment lines recording how it had been verified
after the fact, which made the file 754 bytes longer than what ran. The note was worth
keeping; putting it in the file was not. It is kept here:

- **`20260915230805` — `muster_052_force_password_change_gate`.** Verified after
  applying with `set_config('request.jwt.claims', ...)` inside a rolled-back
  transaction, rather than by changing a real account:
  - *flagged* → `current_user_id` null, `is_super_admin` false, `org_role` null,
    `is_org_member` false, `can_write_org` false, `onboarding_caller` 0 rows;
    `muster_onboarding_status` / `muster_my_workspace` / `muster_ensure_user` raise
    `42501 password_change_required`; `muster_admin_overview` `42501 forbidden`;
    `muster_admin_impersonate_status` `42501`.
  - *unflagged* → the same account resolves to user id 4, `super_admin`, full write.
  - *service* → predicate false.
  - *public* → `muster_plans` and `muster_public_pricing` still answer, as they must.
