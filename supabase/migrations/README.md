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
file would then claim to be the applied statement while no longer being it. It goes in
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

## `055`–`057` call themselves `052`–`054` inside, and that cannot be fixed

`20260916022827`, `20260916022923` and `20260916023009` were written and applied on one
branch while `20260915230805` was being written on another. Both branches took the next
free sequence number, so `muster_052` was claimed twice.

`20260915230805` keeps it. It is earlier by version, and it is the one the **live
database** agrees with: the comment on `muster.password_change_required()` reads
"see migration muster_052 header", so the catalog itself points there. The other three
are renumbered `055`–`057`, which restores unique, chronological numbering.

What is *not* changed is their contents. All three open with a `-- muster_05N:` line and
refer to each other by the old numbers, and those lines are part of the statement
Postgres recorded. Correcting them would make the files disagree with the ledger, which
is the one thing a file here may never do — so the stale self-references stay.
**The filename is authoritative; a `muster_05N` mentioned inside one of these three is
off by three.** The version prefix is the real ordering and always was.

The sequence numbers are a reading aid, not an identifier. Nothing keys on them:
`supabase_migrations.schema_migrations` keys on the version, and so does the CLI.

## `083` and `084` were missing from every branch, found while building a scan-rule audit log

On 2026-09-23, `28footmarketing@gmail.com` applied two migrations straight against
`hjowfnzpomzxazmzywxw` -- `20260923042421` (adds `GOV-006`..`GOV-008`, the AIO-readiness rules
for `llms.txt`, JSON-LD structured data, and script-rendered homepages, all three inactive) and
`20260923042540` (`public.muster_rule_status`, a read-only RPC that looks up named rules' active
state) -- and neither reached `main` or any branch. This surfaced not from `tests/migrations/
ledger.test.ts` or `tools/migrations/check.mjs` (nobody ran either against a fresh dump that day),
but from `muster.scan_rules` itself: a session auditing the rule catalog's own lifecycle found
three `inactive` rows -- `GOV-006`, `GOV-007`, `GOV-008` -- that matched no `insert` anywhere in
this directory, and a live ledger version `084` that collided with a same-numbered file already
in progress on another branch.

Both were recovered here unmodified from `supabase_migrations.schema_migrations.statements`,
verified against that table's own `md5(array_to_string(statements,''))` before being written --
same standard as the `076`–`078` recovery. The live ledger had named them `muster_083` and
`muster_084`, and by version they genuinely are: `20260923042421` and `20260923042540` both
precede `20260923044416`, the already-committed, already-applied `muster_083_catalogue_applies_
when`. Keeping that file's own claim to `083` would have left three files with version order that
disagreed with sequence order -- exactly what `tests/migrations/ledger.test.ts`'s
`sequence_out_of_order` check exists to catch, and it did, the first time this was tried.

So `catalogue_applies_when` is renumbered `085`, the two recovered files take their true `083`
and `084`, and this is the `055`–`057` situation again in miniature: `catalogue_applies_when`'s own
content still opens `-- MUSTER 083:` and cannot be corrected without disagreeing with what
Postgres recorded, so **the filename is authoritative and that header is off by two.**
`CLAUDE.md`'s prose reference to it has been corrected to `085`, because prose is not a frozen
ledger entry and leaving it wrong there would be the "a number written in prose is a snapshot
that rots" mistake CLAUDE.md itself names elsewhere.

One thing this recovery could not do: neither `GOV-006`..`GOV-008` nor `muster_rule_status` has
any engine code. The three rules are inactive with nothing in `supabase/functions/muster-scan/`
that could ever emit them, and the RPC is a live-status lookup, not a history. Recovering the
migration file closes the "applied with no file" gap; it does not mean the feature is built.

## Five more, from a week earlier, found the same way

The same pass turned up five more versions with no file, all from 2026-09-16 and all older than
anything above: `20260916053301`/`20260916053307` (`public.muster_org_scans`, a paginated
org-wide scan-history read path -- real, applied, and until now invisible to this repo),
`20260916192324` (the five `ai_governance` rules: `ai-admt-policy-silent`,
`ai-chatbot-present-undisclosed`, `ai-vendor-undisclosed`, `ai-generated-content-undisclosed`,
`ai-crawler-directives-missing`), and `20260916194544` / `20260916195204` (jurisdiction and
jurisdiction-law seed data for AI-governance tracking). None used the `muster_NNN_` naming
convention, so none needed renumbering -- `tools/migrations/ledger.mjs`'s `SEQ` pattern only
fires on that literal prefix, and a file without one is explicitly not a defect (`README`, above).
All five recovered unmodified and verified against `schema_migrations`'s own md5 first.

**`20260916192324` inserted three of its five rules as `active` with no code that can ever
evaluate them**, and this recovery surfaced it rather than caused it: `ai-chatbot-present-
undisclosed` and `ai-vendor-undisclosed` are `check_type = 'browser'`, `ai-generated-content-
undisclosed` is `check_type = 'manual'`, and this engine is HTTP-native only -- `docs/
SCAN-RULES.md`'s own accessibility section says as much for the browser engine ("0/10 and is not
checked"). All three have sat `active` since 2026-09-16 with `updated_at` unchanged since
`created_at`: nobody has revisited them. That means every scan since has had these three
controls score **met** by the absence of findings the engine was never able to produce -- the
exact failure `muster_062` held `SEC-014`/`SEC-015`/`EMAIL-008` inactive to prevent, now found to
already exist, live, for AI-governance findings a client may be reading as clean. This recovery
does not deactivate them; that changes real client posture scores and is a call for whoever owns
the product, made on purpose, not fixed in passing while recovering a file.

Also found and deliberately **not** recovered here: twelve more versions from later on
2026-09-23 (`create_muster_beta_signups` through `muster_notify_include_industry`), a beta
signup/notification feature with its own edge functions (`muster-beta-signup`,
`muster-beta-confirm`, `muster-beta-export`, `muster-asset-admin`), entirely unrelated to the
scan engine. Recovering those is a separate piece of work for whoever owns that feature.

And one file here claims a version the ledger has never seen: `20260911002553_muster_049_
public_pricing_tier_visibility.sql`. `public.muster_public_pricing` exists live and answers, so
whatever created it works -- but it did not get there through `supabase_migrations.schema_
migrations` under this version, which means either it ran under a different tracked version this
note has not traced yet, or it was applied without the migration tooling. Not a scan-engine
question, so left for a separate look rather than chased down here.

## How to check this directory against the ledger

Neither the numbering collision above nor the two-byte edits were caught by anything;
both were found by hand. They are now checkable:

```
npm run migrations:check -- --sql                    # print the dump query
npm run migrations:check -- --ledger ledger.json     # compare
```

Run the query against `hjowfnzpomzxazmzywxw` with whatever holds credentials — the
Supabase MCP, `psql`, the dashboard SQL editor — and save the JSON array it returns.
The tool takes no connection string and opens no socket, so it cannot leak one. It
reports four things and exits non-zero on any:

| | |
|---|---|
| **diverged** | the file claims to be the applied statement and is not. The database is right. If the dump carried `statement`, it prints the first differing line. |
| **applied with no file** | ran against the database, not recorded here — usually a branch that has not merged. Check before writing a new file; two files for one version is worse than none. |
| **forward reference** | a file for a version the ledger has never seen. This is what left sixteen of them on the old shared project. |
| **local problems** | duplicate versions, duplicate or out-of-order sequence numbers, malformed filenames. |

A file matches when its md5 equals the statement's, or equals it with one trailing
newline appended — the documented difference for files that end in a newline.

The local problems need no database, so `tests/migrations/ledger.test.ts` runs them in
CI on every push. The `muster_052` collision would have failed there the moment it
existed. Gaps in the sequence are deliberately **not** reported: a gap means a branch
has not merged yet, and a check that fails on ordinary in-flight work gets switched off.
