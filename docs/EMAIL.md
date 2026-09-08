# MUSTER email routing

Everything MUSTER sends leaves through **Resend**, from **`mail.muster.partners`** (verified,
sending enabled). But it gets there by two completely separate paths, and conflating them is
the way this breaks silently.

| | Path A — Auth email | Path B — Application email |
|---|---|---|
| Emails | magic link, invite, signup confirmation, email change, password reset, reauthentication | critical/high risk opened (`risk_opened`) |
| Sent by | Supabase Auth (GoTrue) | `muster-alert-dispatch` edge function |
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
| `MUSTER_ALERT_REPLY_TO` | no | unset — no `Reply-To` header is added |

`MUSTER_ALERT_REPLY_TO` has no default on purpose. Receiving is disabled on
`mail.muster.partners`, so a reply to the sending address goes nowhere. Point it at a monitored
inbox and replies start working; leave it unset and the email does not invite one.

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
- **Two Supabase projects.** Auth config does not migrate. Until `hjowfnzpomzxazmzywxw` has SMTP,
  templates, Site URL, and the allowlist set, it cannot send a single auth email — and the
  frontend still points at `mgtmqucaldkaxvxglguw`, so that is the project that has to be correct
  today.
