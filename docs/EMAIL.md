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

**Site URL:** `https://app.muster.partners`

What matters is that it is **on the app host**. Either the root or `/app` works, and the root
is the chosen value.

Root serves `signin.html`, which bounces a session onward itself:

```js
if (session) { window.location.href = WORKSPACE_URL; return; }   // signin.html
```

So a link that falls back to Site URL lands on the sign-in page, the client reads the session
out of the fragment, and the user is redirected to `/app`. The cost against pointing straight
at `/app` is one extra page load and a brief flash of the sign-in form. The gain is that the
value stays correct if `/app` ever moves, and that it keeps `muster-auth-smoke` honest: its
`allowlist:workspace` probe asserts the requested `/app` redirect was honoured, and if Site URL
were *also* `/app` a substituted redirect would be indistinguishable from an honoured one.

What is **not** acceptable is a value off the app host: `https://www.muster.partners/`. That page
is not passive about an auth fragment. `index.html` builds a Supabase client to call
`muster_public_pricing`, and `detectSessionInUrl` defaults to true, so it parsed the
`#access_token=...`, consumed it, and — with `persistSession: false` — stored nothing. Auth links
are single use, so the token was spent and discarded on an origin that could not have used it
anyway, sessions being per-origin. `index.html` now passes `detectSessionInUrl: false`, so the
fragment survives, but the real fix is Site URL pointing at a host that can actually complete a
sign-in.

> **Still wrong as of 2026-09-15.** A magiclink minted 22:48:50 UTC for a real admin account
> (`admin@anthonywashingtonsr.com`) landed on `https://www.muster.partners/` — bare root, no
> path — carrying a live `access_token` and `refresh_token`. Root of `www` is not a redirect
> target any page in this repo asks for: `signin.html` asks for `origin + '/app'` and
> `sitrep.html` asks for `window.location.href`. A link arriving at a target nothing requests is
> the Site URL fallback, which means either Site URL was never moved to the app host on
> 2026-09-13 as this document recorded, or it was moved back. **Verify it in the dashboard
> before assuming either.** Note that `https://www.muster.partners/**` being on the allowlist
> below does *not* explain it — an allowlist entry is only consulted when a `redirect_to` is
> actually sent, and a dashboard-issued magic link or an admin `generateLink` call sends none.

Since 2026-09-15 `index.html` no longer merely declines the fragment — it **forwards** it. A
head-level script runs before the page paints, and if the fragment carries `access_token`,
`refresh_token`, `error_code` or `error_description`, it `location.replace()`s to
`https://app.muster.partners/` with the fragment intact. Declining alone left the user looking at
marketing copy while holding a live session they had no page willing to take; the tokens were
never the problem. The destination is app host **root**, not `/app`, because `signin.html` is the
one page that handles all three arrivals — a live session (bounces to `/app`), `type=recovery`
(shows the new-password form), and an expired link (explains, and offers a fresh one). This is a
belt, not the braces: it stops a wrong Site URL stranding anyone, it does not make Site URL right.
`tests/auth/landing-auth-fragment.test.ts` pins it, including the two negatives that matter — an
in-page anchor (`#pricing`) must never redirect, and the forwarder must not be able to loop.

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
not the `https://app.muster.partners` this document specifies — which is exactly why the
2026-09-09 19:33 magic link landed on the marketing page.

**Re-run this before believing Site URL is fixed.** The 2026-09-15 arrival above says it is not,
and this smoke test is the cheap way to settle it: no email is sent, no token is spent. A run
whose `allowlist:*` probes pass but whose magic links still arrive at `www` root means the
allowlist is fine and Site URL is the thing left to change — they are two different settings on
the same dashboard page, and only one of them is what a link with no `redirect_to` falls back to.

Run 2026-09-23 02:54 UTC, after `.github/workflows/auth-config.yml` set Site URL on 2026-09-17:
**all six read-only steps green, and the fallback is now the app host.** `allowlist:control`
rejected the unknown host and GoTrue fell back to `https://app.muster.partners/`, where the
2026-09-09 run fell back to `https://www.muster.partners/`. That step is the one that proves
Site URL: the two `allowlist:*` probes ask for their redirect by name and pass whatever Site URL
is, while the control asks for a host that must be refused, so the only place it can land is the
fallback. The rest held: `/reset` and `/app` honoured, `/reset` serves the new-password form, and
a minted recovery link for the QA sentinel landed on `app.muster.partners/reset` with a recovery
session in the fragment. It was invoked from Postgres through `pg_net` with the secret read from
Vault inside the database, the way the cron jobs call engine functions, so the secret never left
the project.

What this run does **not** prove, so nobody reads more into it than it says:

- **The password leg.** `rotate_password` was false, so set → sign-in did not run. It last
  passed on 2026-09-09.
- **Magic links specifically.** The smoke test mints a *recovery* link. A magic link goes through
  the same allowlist check and the same Site URL fallback, so this is strong evidence it now lands
  on the app host, but only following a real magic link proves that.
- **Delivery.** Nothing was sent, so this says nothing about SMTP, Resend or which templates are
  live.

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

`category` is a foreign key into `muster.notification_categories` (added `muster_112`) rather than a
hardcoded CHECK -- adding a category is a registry insert plus a `CATEGORY_META` entry in
`muster-alert-dispatch`, not a constraint edit; see `docs/EMAIL-INVENTORY.md`'s "Architecture"
section. Four are registered today: `risk_opened`, `sitrep_ready`, `workspace_created`,
`website_added`. `sitrep_ready` was added 2026-09-26 (`muster_110`):
`public.muster_engine_sitrep()` enqueues it after every scan's SITREP is generated, gated behind
`organizations.sitrep_ready_alerts_enabled` (off by default -- `muster_111` replaced an initial
feature-flag-based gate with this plain column once it turned out `feature_flag_overrides` is
writable only from the super-admin console, so nothing let a tenant turn it on themselves). An
executive toggles it, and sets `sitrep_recipients`, from **Team & Settings** in `app.html` -- see
`docs/EMAIL-INVENTORY.md`. `workspace_created` and `website_added` (`muster_112`, same day) enqueue
from `muster.do_onboard()` and `muster.do_add_website()` respectively -- the latter suppressed for
onboarding's own internal call, so adding a website during onboarding does not also fire a second
email for the same action. A subscription-activated email is not "configuration"; it still needs an
existing-org upgrade path that does not exist yet
either. See `docs/EMAIL-INVENTORY.md`'s "Real gaps, not yet built" for what is and is not there.

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
