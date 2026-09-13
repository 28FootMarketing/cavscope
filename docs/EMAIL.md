# MUSTER email routing

Everything MUSTER sends leaves through **Resend**, from **`mail.muster.partners`** (verified,
sending enabled). But it gets there by two completely separate paths, and conflating them is
the way this breaks silently.

| | Path A — Auth email | Path B — Application email |
|---|---|---|
| Emails | magic link, invite, signup confirmation, email change, password reset, reauthentication | critical/high risk opened (`risk_opened`) |
| Sent by | Supabase Auth (GoTrue) | `muster-alert-dispatch` edge function |
| Delivery tracked by | nothing — GoTrue mail is fire-and-forget | `muster-resend-webhook` → `muster.email_events` |
| Reaches Resend via | **custom SMTP** (`smtp.resend.com`) | **Resend REST API** (`POST /emails`) |
| Templates live in | Supabase project config — sourced from [`supabase/auth-email-templates/`](../supabase/auth-email-templates/) | the edge function (`alertHtml()`) |
| Links controlled by | Supabase **Site URL** + **redirect allowlist** | `MUSTER_APP_URL` env |
| From | `noreply@mail.muster.partners` | `alerts@mail.muster.partners` (`MUSTER_ALERT_FROM`) |

**The trap:** magic-link and password-reset emails are *not* sent by this codebase and cannot be
made to use a Resend template. GoTrue renders and sends them itself. A Resend template named
"Password Reset" would sit in the account and never fire. Path A only reaches Resend at all
because Resend is configured as Supabase's SMTP relay — remove that and auth email falls back to
Supabase's built-in sender, which is throttled to a couple of messages an hour and, on a fresh
project, will only deliver to addresses on the project team. Real users get nothing.

## Path A — required Supabase configuration

None of this is settable by migration, MCP, or SQL. GoTrue keeps it in project config. It is
dashboard work, and it must be repeated on **every project that serves auth**: today
`mgtmqucaldkaxvxglguw`, and again on `hjowfnzpomzxazmzywxw` at cutover.

### 1. SMTP — Authentication → Emails → SMTP Settings

| Field | Value |
|---|---|
| Host | `smtp.resend.com` |
| Port | `465` |
| Username | `resend` (literally the word) |
| Password | a Resend API key with sending permission |
| Sender email | `noreply@mail.muster.partners` |
| Sender name | `MUSTER` |

Create a **separate** Resend API key for this, named `muster-auth-smtp` — do not reuse
`muster-alert-dispatch`. Rotating the alert key should not take sign-in down with it, and the
reverse. Create it in the Resend dashboard rather than through tooling, so the key value never
lands in a transcript or a log.

Then raise the per-hour email rate limit (Authentication → Rate Limits). The default is set for
the built-in sender, not for a real relay, and it is low enough to lock out a client onboarding
a team in one sitting.

### 2. URL configuration — Authentication → URL Configuration

**Site URL:** `https://app.muster.partners/app`

Not the host root. Root on that host is `signin.html`; a signed-in user landing there just
bounces. `/app` is the workspace.

**Redirect URLs** (allowlist — every one of these is a target something already points at):

```
https://app.muster.partners/app
https://app.muster.partners/reset
https://app.muster.partners/**
https://app.muster.28footsystems.com/app
https://app.muster.28footsystems.com/reset
https://app.muster.28footsystems.com/**
https://muster.partners/onboarding
https://muster.partners/**
https://www.muster.partners/**
https://onboarding.muster.28footsystems.com/**
https://sitrep.muster.28footsystems.com/**
```

The last two were added on 2026-09-08 after checking this list against what the code
actually asks for rather than against the host list from memory. Both were missing, and
both would have failed silently.

`sitrep.html` calls `signInWithOtp` with `emailRedirectTo: window.location.href` -- the
page's own URL, whatever host served it. `middleware.js` serves that page on **two** hosts
that were not on this list:

| Host | Serves | Redirect it requests |
|---|---|---|
| `sitrep.muster.28footsystems.com` | `sitrep.html` | `https://sitrep.muster.28footsystems.com/...` |
| `www.muster.partners` | `sitrep.html` at `/sitrep` | `https://www.muster.partners/sitrep` |

`https://muster.partners/**` does not match `www.muster.partners` -- the wildcard covers
the path, not the subdomain.

The symptom would not have looked like a bug. A tenant opening a SITREP link, asked to
sign in, would get the magic link, click it, authenticate successfully, and land on the
workspace at Site URL instead of the SITREP they were trying to read. No error anywhere.
Deriving the redirect from `window.location.href` means every host that serves an
auth-calling page needs an entry; check this list against `middleware.js` whenever a host
is added.

This list is the "forwarded to the correct area" mechanism, and its failure mode is quiet: when
`redirect_to` is **not** on the allowlist, GoTrue does not error — it substitutes Site URL. The
link still works, the user still signs in, and they land somewhere with no password form on it.
The `*.muster.28footsystems.com` entries stay until nothing delivered is still pointing at them.

### 3. Templates — Authentication → Emails

Paste each file from [`supabase/auth-email-templates/`](../supabase/auth-email-templates/) into
its matching template, with the subject line from that directory's README. The files are the
source of truth; edit there first, then paste.

**Not done on `hjowfnzpomzxazmzywxw` as of 2026-09-09.** Two live emails were read back through
`muster-auth-smoke` (below) and neither body contained the MUSTER emblem or footer, so both are
still GoTrue's stock template. The subjects are stock too — `Your sign-in link` and
`Reset your password`, not `Your secure MUSTER sign-in link` and `Reset your MUSTER password`.
Everything mechanical around them is correct; what is missing is the branding.

## Verifying it, rather than assuming it

[`supabase/functions/muster-auth-smoke`](../supabase/functions/muster-auth-smoke/index.ts) checks
this whole document against the live project. It mints a real recovery link with the service-role
key, follows it, sets a password, and signs in with that password. It reports booleans and
redacted origins only — never a token, link or password, per the rule at the top of this file.

```
POST https://hjowfnzpomzxazmzywxw.supabase.co/functions/v1/muster-auth-smoke
  apikey: <publishable key>
  x-muster-secret: <vault muster_cron_secret>
  {"rotate_password": true, "resend_email_id": "<optional Resend email id>"}
```

`rotate_password` defaults to **false**, so the default run mutates nothing. When true, it only
ever touches `sentinel-qa-verify@28footmarketing.com`; the target is a constant in the function,
not a request field, so reaching the endpoint does not let anyone aim it at a real account.

Three things make its passes mean something:

- It probes the allowlist by asking `/auth/v1/verify` for a **deliberately invalid** token. GoTrue
  checks `redirect_to` before it checks the token, so the `Location` header reveals the allowlist
  decision with no email sent and no token consumed.
- It probes a host that must be **rejected**. Without that control, a GoTrue that honoured every
  redirect — an open redirect — would score a clean pass.
- It signs in with the password it just set. A reset nobody can sign in with is not a reset, and
  anything short of that step passes on a password that was never stored.

Run 2026-09-09 20:28 UTC, all steps green except the two template-branding checks above:
the allowlist honours `/reset` and `/app` on both app hosts, rejects an unknown host,
`app.muster.partners/reset` serves `signin.html` with the new-password form, and the full
mint → follow → set → sign-in cycle completed. **Site URL was `https://www.muster.partners/`**,
not the `https://app.muster.partners/app` this document specifies — which is exactly why the
2026-09-09 19:33 magic link landed on the marketing page.

## Path B — application email

`muster-alert-dispatch` drains `muster.notification_outbox` every 5 minutes and sends each row
through the Resend API as multipart HTML + text. Retry policy belongs to
`public.muster_engine_resolve_alert`, not the function: a failed send requeues to `pending` for
up to 5 attempts, then dead-letters to a terminal `failed` that later claims skip.

Edge Function secrets (Supabase dashboard → Edge Functions → Secrets):

| Secret | Required | Default |
|---|---|---|
| `RESEND_API_KEY` | **yes** | none — without it every claimed row resolves `failed` with that exact reason, nothing is lost |
| `MUSTER_ALERT_FROM` | no | `MUSTER Alerts <alerts@mail.muster.partners>` |
| `MUSTER_APP_URL` | no | `https://app.muster.partners/app` |
| `MUSTER_ALERT_REPLY_TO` | no | unset — falls back to `MUSTER_SUPPORT_EMAIL` |
| `MUSTER_SUPPORT_EMAIL` | no | unset — the alert footer then names no support address at all |

Neither has a default, and that is load-bearing: **an advertised address that cannot receive is
worse than no address**, because the tenant writes to it and believes someone read it. Set
`MUSTER_SUPPORT_EMAIL` and the alert footer gains a "Questions about this finding?" line and a
Reply-To; leave it unset and the email behaves exactly as it did before. `MUSTER_ALERT_REPLY_TO`
stays as an override for the case where replies should land somewhere other than the address printed
in the footer, such as a ticketing intake.

### Inbound on `mail.muster.partners`

Receiving was **disabled** on this domain until 2026-09-08 — every address on it was a black hole.
The capability is now enabled in Resend, which is necessary but not sufficient: inbound also needs an
MX record, and until it resolves nothing arrives.

| Type | Name | Value | Priority | TTL |
|---|---|---|---|---|
| MX | `mail` | `inbound-smtp.us-east-1.amazonaws.com` | 10 | Auto |

While that record is missing the domain reads `partially_verified` in Resend. **Sending is
unaffected** — DKIM and both SPF CNAMEs stayed verified, and a send from
`alerts@mail.muster.partners` was confirmed delivered after the capability change.

Do not set `MUSTER_SUPPORT_EMAIL`, and do not put a support address in the frontend, until a real
message to that address has been received. Advertising it earlier is the exact failure this design
avoids.

### Delivery tracking and suppression

`muster-alert-dispatch` records the id Resend returns from `POST /emails`.
`muster-resend-webhook` receives what Resend later reports about that id. Between them they make a
distinction the outbox could not previously express:

| Column | Means |
|---|---|
| `status` | the outbox's own work state: `pending` → `sending` → `sent` / `failed` / `skipped` |
| `delivery_status` | what the provider reported: `accepted` → `delivered`, or `bounced` / `complained` / `failed` |

**A 2xx from the send API only ever produces `accepted`.** Resend accepts, queues, and may still
bounce minutes later. Only an inbound webhook can set `delivered`, and it is the only thing allowed
to. Do not report a MUSTER alert as delivered on the strength of a send response.

Provider events land in `muster.email_events`, keyed by the Svix message id, so a redelivery inserts
nothing. Statuses are rank-guarded: a late `email.sent` cannot overwrite a `delivered`, and a bounce
outranks everything.

A permanent bounce or a spam complaint writes the address to `muster.email_suppressions`.
`muster_engine_claim_alerts` then drops it from every future recipient list, and a row whose
recipients are *all* suppressed terminates as `skipped` with the reason recorded rather than being
sent into a wall. Transient bounces (full mailbox, greylisting) are recorded but never suppress.

Lifting a suppression is a delete from that table. Stored `recipient_emails` are never rewritten, so
delivery resumes with no backfill.

**Resend webhooks are account-wide, not per-domain.** This Resend account also carries BRD, GFFH and
the 28FS domains, so most deliveries reaching the endpoint are about somebody else's mail. The
handler answers them 200 and writes nothing: `muster_engine_record_email_event` matches on
`provider_message_id` against MUSTER's own outbox and returns `matched: false` for everything else.
No other brand's delivery data enters `muster.*`.

Additional Edge Function secret:

| Secret | Required | Notes |
|---|---|---|
| `RESEND_WEBHOOK_SECRET` | **yes, for tracking** | the `whsec_...` Resend shows when the endpoint is created. Without it the function answers 500 and refuses every event rather than trusting an unsigned one. Alert *sending* is unaffected; only tracking stops. |

`risk_opened` is currently the **only** category the outbox accepts — the table's check
constraint permits nothing else. A SITREP-ready notification, a scan-complete digest, or a
welcome email are not "configuration"; each needs a migration to widen that constraint plus
something that actually enqueues rows. None exist yet, and none are pretended to.

## Password reset, end to end

The reset flow did not exist before this was written. There was no way to request one — no
"Forgot password?" anywhere, no `resetPasswordForEmail()` call, and no page to land on. A reset
template would have been unreachable copy.

1. `signin.html` → **Forgot your password?** → `resetPasswordForEmail(email, { redirectTo: origin + '/reset' })`.
2. GoTrue sends `05-reset-password.html` through Resend SMTP.
3. The link hits `<project>.supabase.co/auth/v1/verify?...&type=recovery&redirect_to=…/reset`.
4. The user lands on `/reset`. Middleware already serves `signin.html` for every path on the app
   host that is not `/app`, so `/reset` needs no route of its own.
5. `signin.html` detects recovery — `type=recovery` in the fragment, the `/reset` path, or the
   `PASSWORD_RECOVERY` auth event — and shows the new-password form.
6. `updateUser({ password })`, then into `/app`.

Step 5 is load-bearing. A recovery link **creates a real session**, so the ordinary
"signed in → go to the workspace" rule would have thrown the user straight past the one form
they came for. Recovery is checked first, deliberately.

## Known failure modes

- **Link scanners burn one-time tokens.** Corporate mail security (Outlook Safe Links and
  friends) pre-fetches `/auth/v1/verify`, which consumes the token before the human clicks. The
  user sees "expired". The fix is a `{{ .TokenHash }}` template plus a client-side `verifyOtp`
  page; not built, because it trades a rare failure for a new one on every sign-in. Worth doing
  once a client on locked-down Exchange reports it.
- **Redirect not allowlisted** → silent fallback to Site URL, described above.
- **Two Supabase projects.** Auth config does not migrate. All five frontend pages now point at
  `hjowfnzpomzxazmzywxw`, so **that** is the project whose SMTP, templates, Site URL and allowlist
  have to be correct — the old project no longer serves any auth email a user will see. Its cron is
  inactive on every `muster-*` job, so it dispatches nothing either.
