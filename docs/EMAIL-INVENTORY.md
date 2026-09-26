# CavScope email inventory

Every email CavScope can cause to be sent, the real application event behind it, and **one** owner per
event. The owner column is the point of this document: an event with two owners sends two emails,
and the usual way that happens is somebody adding an email for something the auth or payment
provider already sends.

Routing and configuration: [`docs/EMAIL.md`](EMAIL.md). Auth template sources:
[`supabase/auth-email-templates/`](../supabase/auth-email-templates/).

**2026-09-26: the SITREP itself, and the risk_opened alert, still said "MUSTER."** Found by sending
real rendered samples of every category for review and reading them, not by grep. `muster.q_brand()`
-- what every non-white-labeled SITREP, workspace header, and report footer reads its product name
from -- still returned `brand_name: 'MUSTER'`, `brand_mark: 'MU'`, and a "Prepared under the MUSTER
Assurance Framework" disclaimer as its default. `muster.autotriage()`'s risk_opened email still said
`[MUSTER] New ... risk` and `MUSTER opened a new risk`. Fixed (`muster_114`, `muster_115`,
`muster_116`) along with the same word in `generate_sitrep`, the jurisdiction section, the control
register, finding-promotion text, brand-settings plan-gate errors, the beta-signup deadline message,
and the MCP agent tool catalog -- everywhere a real reader (customer or AI agent) sees it. The
lowercase sentinel `'mode': 'muster'` and the `hide_muster_attribution` key name are unchanged on
purpose: `app.html` compares against those literal strings, so they are the internal identifiers
CLAUDE.md's brand note is about, not display text. `tests/migrations/cavscope-branding.test.ts`
guards the two functions that were retyped by hand (`q_brand`, `autotriage`) against regression, and
pins `muster_116`'s fix-list for the rest.

## Architecture

Every CavScope-owned (as opposed to GoTrue- or Stripe-owned) transactional email goes through one
pipeline: an event handler inserts a row into `muster.notification_outbox`, `muster-alert-dispatch`
claims up to 20 pending rows every 5 minutes and sends each through the Resend REST API, and
`muster-resend-webhook` records what Resend later reports. This is deliberately the **only** such
pipeline — a second one-off `fetch("https://api.resend.com/emails")` anywhere else in the codebase
is a bug, not a shortcut.

- **Categories are a registry, not a CHECK constraint** (`muster.notification_categories`, added
  `muster_112`). Adding a category is one insert there plus a `CATEGORY_META` entry in
  `muster-alert-dispatch`, not a migration editing a literal-equality constraint — the same
  discipline this codebase already applies to `muster.frameworks` and `muster.feature_flags`.
- **Templates are one function, `alertHtml()`, keyed by category** (`CATEGORY_META`: eyebrow text,
  CTA label/link, recipient-note copy). Body copy itself is built by whatever enqueues the row
  (SQL, mostly) and passed through as `body_text`, paragraph-split and escaped — never raw HTML from
  a caller.
- **Delivery logging**: `muster.email_events` (Resend webhook, keyed by Svix message id) plus
  `delivery_status`/`delivered_at` on the outbox row itself. See `docs/EMAIL.md`.
- **Retry-safe**: `muster_engine_resolve_alert` requeues a failed send to `pending` for up to 5
  attempts, then dead-letters to `failed`; the Resend call itself carries an `Idempotency-Key` keyed
  on the outbox row id, and a `X-Entity-Ref-ID` header so Gmail does not collapse distinct alerts
  into one thread.
- **Configuration is environment variables**: `RESEND_API_KEY`, `MUSTER_ALERT_FROM`,
  `MUSTER_APP_URL`, `MUSTER_SITREP_URL`, `MUSTER_SUPPORT_EMAIL`, `MUSTER_ALERT_REPLY_TO` — see
  `docs/EMAIL.md`.
- **Light/dark rendering**: the template ships `color-scheme`/`supported-color-schemes` meta tags
  and a `<style>` block with `@media (prefers-color-scheme: dark)` overrides (`!important`, since
  that is the only thing that beats an inline style's specificity in an email client). Clients that
  honor it (Apple/iOS/Android Mail, Gmail's app) get a dark card; clients that ignore media queries
  (Outlook desktop) get the light card unchanged — no regression either way.
- **Transactional vs. marketing**: hard-separated already. Marketing lives in GHL against the
  `src:`/`product:`/`intent:` tag taxonomy, a different sending identity and a different suppression
  list. Nothing in this pipeline shares either with GHL.
- **Suppression**: a permanent bounce or spam complaint on any Resend send (any category) writes
  `muster.email_suppressions`; `muster_engine_claim_alerts` drops a suppressed address from every
  future recipient list, regardless of category.

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
| Workspace ready | `muster.do_onboard()` creates a new organization | the creating user | **CavScope** (Resend REST API) | `alertHtml()`, `workspace_created` category |
| Website added | `muster.do_add_website()` adds a website, except when called from onboarding (folded into Workspace ready instead — see below) | org's alert recipients (executive/risk_owner) | **CavScope** (Resend REST API) | `alertHtml()`, `website_added` category |

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

Named rather than quietly implemented. `muster.notification_categories` (above) currently registers
`risk_opened`, `sitrep_ready`, `workspace_created` and `website_added`; nothing else, on purpose.

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
| Subscription activated for an **existing** user | A user who already has an account and upgrades gets no email at all. A new user gets the GoTrue invite, so only this case is unserved. | Not just an email: `muster.do_onboard` is the only place a pending commercial grant is ever applied to an organization's plan, and it only runs when a **new** org is created. There is no code path that applies a grant to an **existing** org yet, so an "activated" email at checkout time would claim a plan change the schema cannot confirm happened. Build the existing-org upgrade path first; widen the registry to `subscription_activated` and enqueue from it once that path is real. |
| Website down / restored | Nothing tells anyone a site went unreachable or came back, in near-real time. | Real new infrastructure, not just an email: see "Website down / restored" below -- the platform has no continuous uptime monitor to hang this off of today. |

### 2026-09-26 request reconciliation: 14 proposed transactional emails

A 14-item transactional-email spec was requested that (understandably, without deep knowledge of
what this repo already builds and has already decided) re-proposes several emails this document
already assigns elsewhere, and two more that assume monitoring infrastructure that does not exist.
Reconciled here rather than built blind, because several of these are "GoTrue already sends this"
or "Stripe already owns this" -- building a second sender is the exact one-owner-per-event failure
this whole document exists to prevent, and getting it wrong here means a real customer gets two
emails (or, for billing, two receipts) for one event.

| # | Requested event | Verdict | Why |
|---|---|---|---|
| 1 | Verify Your Email | **Already GoTrue's**, and mostly moot | Self-serve signup is paused (`signin.html` has no signup form); every real account today arrives via a GoTrue invite (`muster-stripe-webhook` → `inviteUserByEmail`, or a manual dashboard invite) or admin provisioning, not a self-serve signup that needs its own confirmation. `01-confirm-signup.html` exists in `supabase/auth-email-templates/` for if/when self-serve returns; CavScope building a second one would either duplicate GoTrue's or ship for a flow the product doesn't have. |
| 2 | Welcome to CavScope | **Already listed, GoTrue's invite** | This table has said so since it was written: "the invite email *is* the welcome... A separate welcome would arrive within seconds of it." Unchanged. |
| 3 | Password Reset | **GoTrue's**, fully wired | `docs/EMAIL.md`'s entire "Password reset, end to end" section documents this working today via `resetPasswordForEmail` / `05-reset-password.html`. CavScope cannot intercept or duplicate this — GoTrue sends it, not this codebase. |
| 4 | Password Changed | **GoTrue's, and off — that's a standing decision, not an oversight** | CLAUDE.md is explicit: `mailer_notifications_password_changed_enabled` is one of "the seven security-notification emails," currently `false`, and turning it on is called out by name as **the owner's call** — a customer-facing security-posture decision, not a code change. This is not CavScope's to send even if GoTrue's were switched on; it is GoTrue's own template (still stock at ~190 characters) that would need writing first. Flagging for a decision, not building around it. |
| 5 | Workspace Ready | **Built** | `workspace_created` category, above. |
| 6 | Website Added | **Built** | `website_added` category, above -- suppressed specifically for the onboarding trigger so it does not double up with Workspace Ready for the same action. |
| 7 | Initial Assurance Scan Complete | **Already `sitrep_ready`** | Identical trigger point to SITREP ready (`muster_engine_sitrep`, unconditional after every scan) — see "scan complete is not a separate row" above. `sitrep_ready`'s copy already names posture band/score; if a visually distinct "first scan" variant is wanted, that is a copy change inside the existing `sitrep_ready` category (e.g. detect `version = 1` and vary the subject), not a second category and a second email for the same scan. |
| 8 | SITREP Ready | **Already built**, before this request arrived | `sitrep_ready`, this session. The requested field list (assurance status, critical/high/medium counts, resolved-since-last count) is richer than the current `body_text` (posture band/score + headline only) — worth a follow-up pass to pull those counts from `muster.sitreps.sections`/`citations`, but that is a copy change to the existing category, not a new one. |
| 9 | Critical Finding Detected | **Already `risk_opened`**, narrower scope requested | `muster.autotriage()` already emails the moment a critical **or** high risk opens, gated on `critical_alerts_enabled`, to executives/risk owners — same trigger, same "avoid alert fatigue" intent, already excludes medium/low/informational by construction (`notification_outbox_severity_check` only permits `critical`/`high`/`info`). The request asks for critical-only; that is a one-line filter change inside the existing `autotriage()` enqueue condition, not a second, competing alert for the same finding. |
| 10 | Website Down | **Needs new infrastructure, not an email** | See below. |
| 11 | Website Restored | **Needs new infrastructure, not an email** | See below. |
| 12 | Payment Successful | **Already Stripe's, by deliberate decision** | "Payment receipt / invoice: Stripe... CavScope holds no line items and no tax detail, so anything it sent would be a worse duplicate," above. Reversing this is a real option (a branded receipt strategy is legitimate), but it is a product decision that also needs new Stripe webhook subscriptions (today only `checkout.session.completed` is consumed — see `muster-stripe-webhook`), not something to build silently under an unrelated request. |
| 13 | Payment Failed | **Already Stripe's, by deliberate decision** | Same table, "Stripe owns dunning, the retry schedule, and the hosted payment-update page." Needs `invoice.payment_failed` subscribed and handled — does not exist today. |
| 14 | Subscription Canceled | **Already Stripe's, by deliberate decision, and a known unhandled gap** | Same table: "CavScope is not told the difference between a cancel-at-period-end and an immediate cancel unless it subscribes to more events than it currently does." CLAUDE.md independently flags `customer.subscription.deleted` as unhandled by `muster-stripe-webhook` today. Building this email requires building that webhook handler first — real, but separate, work. |

**Net new work done in this pass:** `workspace_created`, `website_added`, the category-registry
architecture, and light/dark rendering support. **Deliberately not done:** anything above marked
GoTrue's/Stripe's (5 items) or already-covered (3 items) — building those would ship a duplicate or
a false claim. **Needs a decision before building:** password-changed notifications (GoTrue
template + the owner's sign-off), billing emails (new Stripe webhook subscriptions + confirming
CavScope wants a second, branded receipt alongside Stripe's), and website down/restored (see next).

### Website down / restored

Not built, and not safely buildable as "an email" alone. The platform has **no continuous uptime
monitor** — the only availability signal comes from the scan engine's own `AVAIL-001`/`AVAIL-003`/
`AVAIL-004` rules, evaluated once per scan, on a cadence that defaults to 1440 minutes (daily; see
`muster.website_scan_settings.cadence_minutes`). There is no polling loop, no consecutive-failure
counter distinct from scan-to-scan comparison, and no cron job for it (the five `muster-*` cron
schedules are `scan-due`, `autotriage`, `alert-dispatch`, `watchdog` — platform self-health, not
website uptime — and `embedding-backfill`).

Sending a "Website Down"/"Website Restored" email off today's data would say things the platform
cannot back up: a "detection time," a "current outage duration," and "respect the existing
multiple-failed-check confirmation logic" all describe near-real-time monitoring semantics this
product does not have. A site scanned once daily could be down anywhere from one minute to nearly
24 hours before an `AVAIL-*` finding ever fires, and "restored" would only be noticed on the next
scan — up to a day later. That is precisely the class of bug `docs/CLAUDE.md`'s AVAIL-001/AVAIL-003/
AVAIL-004 history is about: a confident, specific-sounding claim ("detected at 14:32", "down for 3
hours") about something the engine never actually measured that way. Two honest paths forward,
neither of which is "just add the email":

1. **Build real, frequent uptime polling** as new infrastructure (a dedicated cron + a
   consecutive-failure counter per website, independent of the scan cadence) — a genuine feature,
   not a notification bolt-on, and the only way the requested copy ("detection time," "outage
   duration," "multiple failed checks") would be true.
2. **Derive it from scan-to-scan `AVAIL-*` transitions only**, with copy that says what actually
   happened — "as of the scan run at ..., this site did not respond" rather than "detected at" — at
   the cost of being accurate only to within one scan cadence, which for most orgs is a day.

This needs the owner's call before either is built.

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
