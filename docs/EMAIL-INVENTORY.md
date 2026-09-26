# CavScope email inventory

Every email CavScope can cause to be sent, the real application event behind it, and **one** owner per
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
| Critical/high risk opened | `muster.autotriage()` opens a risk → row in `muster.notification_outbox` → `muster-alert-dispatch` every 5 min | org's alert recipients | **CavScope** (Resend REST API) | `alertHtml()` in the function |
| SITREP ready | `public.muster_engine_sitrep()` generates a SITREP after every scan → row in `muster.notification_outbox` → `muster-alert-dispatch` every 5 min. Gated on `organizations.sitrep_ready_alerts_enabled`, off by default. Toggle and recipients are set from **Team & Settings** in `app.html` (`muster_set_sitrep_alert_preference`, `muster_set_sitrep_recipients`). | `organizations.sitrep_recipients`, falling back to executive/risk_owner members | **CavScope** (Resend REST API) | `alertHtml()` in the function, `sitrep_ready` category |

## Deliberately not sent by CavScope

Each of these has an owner already. Building a CavScope version would produce a second email for one
event, which is the failure this table exists to prevent.

| Event | Owner | Why not CavScope |
|---|---|---|
| Payment receipt / invoice | **Stripe** | Stripe emails receipts and invoices when the customer email is collected. CavScope holds no line items and no tax detail, so anything it sent would be a worse duplicate. Enable it in Stripe → Settings → Customer emails. |
| Payment failure, card action required | **Stripe** | Stripe owns dunning, the retry schedule, and the hosted payment-update page. CavScope has no equivalent and should not compete with the retry timeline. |
| Subscription cancellation confirmation | **Stripe** | Same. CavScope is not told the difference between a cancel-at-period-end and an immediate cancel unless it subscribes to more events than it currently does. |
| Trial ending | **Stripe** | No CavScope tier currently offers a trial. If one is introduced, Stripe's trial-ending email is the owner; do not add a second. |
| Welcome after account creation | **GoTrue invite** | The invite email *is* the welcome for every paid client: `muster-stripe-webhook` invites on `checkout.session.completed`, and the invite lands the user in onboarding. A separate welcome would arrive within seconds of it. |
| Promotional / campaign email | **GHL** | Marketing lives in GHL against the `src:` / `product:` / `intent:` tag taxonomy. It must not share a sending identity or a suppression list with transactional mail. |

## Real gaps, not yet built

Named rather than quietly implemented, because each needs a migration to widen
`notification_outbox`'s category constraint plus something that actually enqueues rows. The
constraint now permits `risk_opened` and `sitrep_ready` (added 2026-09-26, `muster_110`); nothing
else, on purpose.

**"Scan complete" is not a separate row in this table.** `public.muster_engine_sitrep()` runs
synchronously, unconditionally, right after every scan -- scheduled, manual and admin-sandbox
alike -- so "a scan finished" and "a SITREP is ready" are the same event. Building both would be
exactly the one-owner-per-event failure this document exists to prevent; `sitrep_ready` is the one
category for it.

`sitrep_ready` shipped in `muster_110` gated behind a NEW feature flag, `sitrep_ready_email`
(`default_enabled = false`) -- and `muster_111` retired that flag one migration later.
`feature_flag_overrides` is writable only from the super-admin console (every `muster_admin_*`
write RPC checks `muster.is_super_admin()` itself, backed by RLS); there was no code path for an
ordinary executive to flip an override on their own org, so "enable it per org" was a switch only a
super admin could reach -- not actually wired to a page. `muster_111` replaced it with a plain
column, `organizations.sitrep_ready_alerts_enabled`, the same shape as the sibling
`critical_alerts_enabled` (a per-org preference an executive/contributor+ flips themselves via
`muster.can_write_org`), rather than a second admin-only flag stacked under a category-specific
preference. It still defaults **false**: websites default to a 1440-minute (daily) scan cadence,
and shipping this on for every existing org with no prior warning is the "digest nobody can turn
off is a complaint generator" problem this table used to describe. `email_alerts` is unaffected and
still gates the outbox claim for every category, including this one.

| Event | Who is unserved today | What it needs |
|---|---|---|
| Subscription activated for an **existing** user | A user who already has an account and upgrades gets no email at all. A new user gets the GoTrue invite, so only this case is unserved. | Not just an email: `muster.do_onboard` is the only place a pending commercial grant is ever applied to an organization's plan, and it only runs when a **new** org is created. There is no code path that applies a grant to an **existing** org yet, so an "activated" email at checkout time would claim a plan change the schema cannot confirm happened. Build the existing-org upgrade path first; widen `category` to `subscription_activated` and enqueue from it once that path is real. |

## Support contact

There is no support address in the product today. All four `mailto:` links —
`index.html` (two), `signin.html`, `app.html`'s auth modal — are **sales** intent
(`sales@28footsystems.com`), for getting an organization provisioned. A paying client with a problem
has no route anywhere: not in the workspace, not in the SITREP viewer, not in an alert email. The
landing page meanwhile sells "Priority support & SLA options" on the enterprise tier.

The alert email is now ready for one: set `MUSTER_SUPPORT_EMAIL` and its footer gains a support line
and a Reply-To. It is gated on that secret precisely so the address cannot be advertised before it
can receive.

Frontend support links are deliberately **not** added yet. Static HTML cannot be gated on a secret,
so putting `support@mail.muster.partners` in a page ships a dead address to production the moment it
merges. Those links go in once inbound is verified — see the MX record in
[`EMAIL.md`](EMAIL.md#inbound-on-mailmusterpartners).

## Rules

- **One owner per event.** Before adding an email, check this table and the provider dashboards.
- **Transactional and promotional stay separate.** Different systems, different suppression lists.
- **Auth email cannot be templated in Resend.** GoTrue renders and sends it; Resend is only the SMTP
  relay. A Resend template named "Password Reset" would sit unused. See `docs/EMAIL.md`.
- **Escape everything interpolated.** Scanner output reaches `alertHtml()`; it goes through `esc()`
  and blank-line paragraph splitting, and nothing else in the body is interpreted as markup.
- **Do not put account, financial, or finding detail in an email that a subject line can carry.**
  The alert email names severity and title and links to the register; it does not reproduce evidence.
