# MUSTER email inventory

Every email MUSTER can cause to be sent, the real application event behind it, and **one** owner per
event. The owner column is the point of this document: an event with two owners sends two emails,
and the usual way that happens is somebody adding an email for something the auth or payment
provider already sends.

Routing and configuration: [`docs/EMAIL.md`](EMAIL.md). Auth template sources:
[`supabase/auth-email-templates/`](../supabase/auth-email-templates/).

## Implemented and wired

| Event | Trigger | Recipient | Owner | Template |
|---|---|---|---|---|
| Magic-link sign-in | `signin.html` / `sitrep.html` / `app.html` call `signInWithOtp` | the address typed | **GoTrue** via Resend SMTP | `03-magic-link.html` |
| Password reset | `signin.html` → Forgot your password → `resetPasswordForEmail` | the address typed | **GoTrue** | `05-reset-password.html` |
| Email verification / confirm signup | GoTrue signup confirmation | new user | **GoTrue** | `01-confirm-signup.html` |
| Team or client invitation | `muster-stripe-webhook` → `inviteUserByEmail`, or a manual dashboard invite | invited address | **GoTrue** | `02-invite-user.html` |
| Email-address change | user changes their address in Supabase Auth | both old and new address | **GoTrue** | `04-change-email.html` |
| Reauthentication code | GoTrue reauthentication | signed-in user | **GoTrue** | `06-reauthentication.html` |
| Critical/high risk opened | `muster.autotriage()` opens a risk → row in `muster.notification_outbox` → `muster-alert-dispatch` every 5 min | org's alert recipients | **MUSTER** (Resend REST API) | `alertHtml()` in the function |

## Deliberately not sent by MUSTER

Each of these has an owner already. Building a MUSTER version would produce a second email for one
event, which is the failure this table exists to prevent.

| Event | Owner | Why not MUSTER |
|---|---|---|
| Payment receipt / invoice | **Stripe** | Stripe emails receipts and invoices when the customer email is collected. MUSTER holds no line items and no tax detail, so anything it sent would be a worse duplicate. Enable it in Stripe → Settings → Customer emails. |
| Payment failure, card action required | **Stripe** | Stripe owns dunning, the retry schedule, and the hosted payment-update page. MUSTER has no equivalent and should not compete with the retry timeline. |
| Subscription cancellation confirmation | **Stripe** | Same. MUSTER is not told the difference between a cancel-at-period-end and an immediate cancel unless it subscribes to more events than it currently does. |
| Trial ending | **Stripe** | No MUSTER tier currently offers a trial. If one is introduced, Stripe's trial-ending email is the owner; do not add a second. |
| Welcome after account creation | **GoTrue invite** | The invite email *is* the welcome for every paid client: `muster-stripe-webhook` invites on `checkout.session.completed`, and the invite lands the user in onboarding. A separate welcome would arrive within seconds of it. |
| Promotional / campaign email | **GHL** | Marketing lives in GHL against the `src:` / `product:` / `intent:` tag taxonomy. It must not share a sending identity or a suppression list with transactional mail. |

## Real gaps, not yet built

Named rather than quietly implemented, because each needs a migration to widen
`notification_outbox`'s category constraint plus something that actually enqueues rows. The
constraint currently permits `risk_opened` and nothing else, on purpose.

| Event | Who is unserved today | What it needs |
|---|---|---|
| Subscription activated for an **existing** user | A user who already has an account and upgrades gets no email at all. A new user gets the GoTrue invite, so only this case is unserved. | Widen `category` to `subscription_activated`, enqueue from `muster_engine_record_commercial_grant` **only when the auth user already existed**, and make `alertHtml()` category-aware. |
| SITREP ready | Nobody is told a SITREP has been generated. | Widen `category`, enqueue from the SITREP generator. |
| Scan complete / weekly digest | No digest exists. | Widen `category`, plus a schedule and a per-org preference, since a digest nobody can turn off is a complaint generator. |

## Rules

- **One owner per event.** Before adding an email, check this table and the provider dashboards.
- **Transactional and promotional stay separate.** Different systems, different suppression lists.
- **Auth email cannot be templated in Resend.** GoTrue renders and sends it; Resend is only the SMTP
  relay. A Resend template named "Password Reset" would sit unused. See `docs/EMAIL.md`.
- **Escape everything interpolated.** Scanner output reaches `alertHtml()`; it goes through `esc()`
  and blank-line paragraph splitting, and nothing else in the body is interpreted as markup.
- **Do not put account, financial, or finding detail in an email that a subject line can carry.**
  The alert email names severity and title and links to the register; it does not reproduce evidence.
