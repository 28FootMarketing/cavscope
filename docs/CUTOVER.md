# MUSTER cutover to `hjowfnzpomzxazmzywxw`

The old shared project `mgtmqucaldkaxvxglguw` is still serving production. This file is
the ordered remainder. Steps 1 and 2 are dashboard work that no tool in the build
environment can reach; everything after them is gated on those two.

## Done

| | |
|---|---|
| Schema, RLS, policies, triggers, functions, shims | verified checksum-identical to source |
| Data | 708 rows, 42 tables, byte-identical |
| Edge functions | all 8 byte-identical on both projects and to this repo |
| **Auth users** | **3 users + 3 identities, byte-identical to source** |
| Repo | frontend, `config.toml`, migrations directories all point at the new project |
| Grants | reconciled to source (`muster_032`); advisors show no divergence from the old project |

The three auth users moved with their **UUIDs and bcrypt password hashes intact**
(`auth.users` md5 `a2876dbd50c2001eb4e017fc63975aed`, `auth.identities` md5
`1ea187cec0977a5313e6f0a923f5c406`). `muster.users.auth_user_id` has no FK to
`auth.users`, so matching UUIDs is the only thing binding the imported rows to the
accounts — all 3 verified bound. **Existing passwords work.** Nothing needs resetting,
which matters because step 1 is what makes password *reset* possible at all.

## 1. GoTrue configuration — Supabase dashboard, new project

None of this is in the database or in this repo. Auth config does not migrate between
projects; it has to be set on `hjowfnzpomzxazmzywxw` by hand.

Follow `docs/EMAIL.md` §1 and §2 exactly — it already carries the values:

- **SMTP** (Authentication → Emails → SMTP Settings): `smtp.resend.com`, port `465`,
  username literally `resend`, sender `noreply@mail.muster.partners`, name `MUSTER`.
  Password is a **new** Resend key named `muster-auth-smtp` — create it in the Resend
  dashboard, not through tooling, so the value never lands in a transcript or a log. Do
  not reuse the `muster-alert-dispatch` key; rotating one should not take the other down.
- **Rate limits** (Authentication → Rate Limits): raise the per-hour email limit. The
  default is sized for the built-in sender and will lock out a client onboarding a team
  in one sitting.
- **Site URL:** `https://app.muster.partners/app` — not the host root. Root is
  `signin.html`; a signed-in user landing there just bounces.
- **Redirect allowlist:** all nine entries from `docs/EMAIL.md` §2. Its failure mode is
  silent — an un-allowlisted `redirect_to` is not an error, GoTrue substitutes Site URL,
  and the user lands somewhere with no password form on it.
- **Templates:** paste all six from `supabase/auth-email-templates/`. They use GoTrue
  variables (`{{ .ConfirmationURL }}`, `{{ .Token }}`), not Resend template syntax — a
  Resend *template* can never render them.
- **Leaked password protection:** enable it (Authentication → Policies). The advisors
  flag this on **both** projects, so it is a pre-existing gap being closed, not a
  regression introduced by cutover.

Verify before moving on: request a magic link for `anthony@28footmarketing.com` against
the new project and confirm it arrives and lands on `/app`.

## 2. Edge function secrets — dashboard, new project

Split by where they live, because the two halves are not equally reachable.

**Vault entries — DONE.** All three are set on the new project and verified:

| Entry | Status |
|---|---|
| `muster_cron_secret` | set; `muster_engine_secret()` resolves it |
| `supabase_anon_key` | set; decodes to `ref=hjowfnzpomzxazmzywxw`, `role=anon` |
| `muster_ghl_webhook_secret` | copied from source, md5 `23fdaffd2e7cb37300cd96fa15dd6249` on both; `muster_ghl_webhook_secret()` resolves it |

The GHL secret was **copied rather than regenerated** on purpose: the value has to match
what GHL is already configured to send, so GHL needs only a URL change at cutover, not a
secret change as well. Moved server-to-server over `pg_net` (`muster_033`, dropped by
`muster_034`) so it never appeared as a literal.

**Edge function secrets — still unset, and not settable from the build environment.**
`RESEND_API_KEY`, `STRIPE_WEBHOOK_SECRET`, `GHL_API_KEY`, `GHL_LOCATION_ID`. These are
Deno env vars on the function runtime, not database objects; no tool available here reads
or writes them. Dashboard → Edge Functions → Secrets.

For `RESEND_API_KEY`, **use the existing `muster-alert-dispatch` Resend key** — it was
created 2026-09-06 and is already MUSTER-scoped. Do not point MUSTER at a shared key: the
same shared-credential pattern took MUSTER down once already when a spend cap on the
shared `OPENROUTER_API_KEY` was hit by another brand (2026-09-06, recorded in
`muster-agent/index.ts`). Edge function secrets are project-scoped and this project is
MUSTER's alone, so plain `RESEND_API_KEY` here means MUSTER's key and nothing else's —
which is why `muster-alert-dispatch` reads it with no `MUSTER_*` fallback.

`mail.muster.partners` is verified in Resend with sending enabled, so the from-address
works as soon as the key is set.

## 3. Merge the frontend PR

Only after 1 and 2. Merging earlier points the deployed frontend at a project that
cannot send a single auth email.

## 4. Swap the cron jobs — DONE 2026-09-08

**Executed.** All five disabled on `mgtmqucaldkaxvxglguw`, all five enabled on
`hjowfnzpomzxazmzywxw`, old side first so the two never overlapped.

Checked before flipping anything, because the jobs were copied from a project whose URL
is baked into their command bodies:

- Four of the five POST to `https://hjowfnzpomzxazmzywxw.supabase.co/functions/v1/...`
  — the new project, not the old. `muster-autotriage-15min` has no URL at all; it runs
  `select muster.autotriage();` in-database, so it is correct by construction.
- `vault.supabase_anon_key` on the new project decodes to `ref=hjowfnzpomzxazmzywxw`,
  `role=anon` — it is that project's own key, not a copy of the old one. Had it been
  copied, every HTTP job would have 401'd.
- `vault.muster_cron_secret` is present and is read by the same project's
  `muster_engine_secret()`, so it is self-consistent whatever its value.

Then the chain was proven end to end on the safest job before enabling any of them —
`muster-watchdog` is read-only, opens incidents only, never emails:

```
cron_safe_post -> pg_net -> muster-watchdog -> HTTP 200 {"checks_run":5,"incidents_opened":0}
```

That single call exercised the vault secrets, `cron_safe_post`, the pg_net worker, the
edge function's `x-muster-secret` check against `muster_engine_secret()`, and the
watchdog RPCs. Worth repeating on any future project move; it is much cheaper than
discovering a 401 from a cron log.

The original instructions are kept below, since they are what to run if this ever has to
be reversed.

### Reversing

Swap the two statements: disable on `hjowfnzpomzxazmzywxw`, enable on
`mgtmqucaldkaxvxglguw`. This stops being a clean reversal as soon as the new project has
written scans, SITREPs or findings the old one does not have — after that, reversing
means reconciling data.

On `mgtmqucaldkaxvxglguw` (disable first):

```sql
select cron.alter_job(jobid, active := false)
from cron.job where jobname in (
  'muster-scan-due','muster-autotriage-15min','muster-alert-dispatch-5min',
  'muster-watchdog-10min','muster-embedding-backfill-15min');
```

Then on `hjowfnzpomzxazmzywxw`:

```sql
select cron.alter_job(jobid, active := true)
from cron.job where jobname in (
  'muster-scan-due','muster-autotriage-15min','muster-alert-dispatch-5min',
  'muster-watchdog-10min','muster-embedding-backfill-15min');
```

Use `cron.alter_job`, not `update cron.job set active` — the role has EXECUTE on the
function and no write privilege on the table.

Confirm on both: `select jobname, active from cron.job where jobname ilike '%muster%';`

## 5. Stripe webhook

Repoint the `checkout.session.completed` endpoint at the new project's
`muster-stripe-webhook`, and set `STRIPE_WEBHOOK_SECRET` from the signing secret Stripe
shows once at registration. The function verifies HMAC-SHA256 against the raw body, so a
mismatched secret fails closed with a 401 rather than provisioning wrongly.

## 6. `public.apply_approved_kb_updates()` — a decision, not a task

That function lives on the **old** project and writes into `muster.jurisdiction_laws`.
It is CORA/JARVIS code, not MUSTER's. After cutover it writes to a schema nothing reads.
Either repoint it at the new project or retire the path, but it should not be left
silently updating a dead copy.

## Rollback

The old project is untouched and complete: schema, data, edge functions, and its cron
still active until step 4. Reverting is `git revert` of the frontend commit plus
re-enabling its cron. That stays true until step 4 runs — after it, the two databases
begin to diverge and rollback means reconciling data, not flipping a switch.
