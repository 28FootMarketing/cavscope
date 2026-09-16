# MUSTER — standing rules for this repo

## Tooltips are mandatory on every page

Every page in this repo (`index.html`, `app.html`, `admin.html`, `signin.html`, `onboarding.html`, `sitrep.html`, `sitrep-sample.html`, and any future page) must have
tooltips on its interactive and informational elements — buttons, links, nav items, form fields,
status indicators, data points, badges, chips, and anything else a user might not immediately
understand. This is a standing requirement; do not wait to be asked again per page or per change.

**When adding new UI to any page:**
- Add a `data-tooltip="..."` attribute to every new button, link, label, badge, chip, or data element
  that isn't self-explanatory from its visible text alone.
- Write the tooltip text from the reader's side: explain what it does or what it means, not how the
  code implements it.
- If the page doesn't already have the tooltip engine (check for `.app-tooltip` in its `<style>` and
  `initTooltips()` in its `<script>`), add it — copy the implementation from `app.html`'s
  `initTooltips()` function and `.app-tooltip` CSS class verbatim. It's a small (~60 line), dependency-free,
  accessible (keyboard focus, Escape to dismiss, `aria-describedby`) delegated-event tooltip system with
  no external library.
- Verify with `node --check` after editing (extract the inline `<script>` block first) before committing.

## Right-click is suppressed on every page, and it is not a security control

Every page calls `initContextMenuGuard()` alongside `initTooltips()`. It suppresses the browser
context menu on a mouse right-click. It was added 2026-09-08 at the owner's explicit request, after
the tradeoff was put to them in full, and a new page must include it the same way tooltips are
included.

**It does not protect page source, and it must never be described to a client, in a SITREP, or in a
control register as if it does.** `Ctrl+U`, `F12`, the browser's own View Page Source item, `curl`,
Save Page As, and simply disabling JavaScript all still read every byte. The protection that is real
is architectural and already in place: auth, RLS, the scan engine, posture scoring, control
derivation and SITREP generation run in Postgres and edge functions, and what ships to a browser is
a renderer.

Two carve-outs are deliberate and are pinned by `tests/ui/context-menu-guard.test.ts`. Do not remove
either to make the block "more complete" — each exists because MUSTER sells accessibility auditing
(`A11Y-001`..`A11Y-007`) and would otherwise be shipping the defect it scans for:

- **Keyboard-invoked menus pass through.** Menu key and Shift+F10 arrive as a `contextmenu` event
  with `button === 0`; a mouse right-click arrives with `button === 2`. Only `2` is suppressed, so
  screen reader and keyboard-only users keep the menu. Touch long-press also reports `0`, so mobile
  copy and paste keeps working — a long-press is not a right-click.
- **Text-entry surfaces keep their native menu.** `input`, `textarea` and `contenteditable` are
  excluded, because right-click there is how people paste and reach spellcheck suggestions, and a
  form field exposes no source.

## Design tokens live in one file and are generated into the pages

`assets/tokens.css` is the source of truth for every colour, font stack, radius and shadow.
It is **not served to a browser**. Each page carries an inlined copy inside its `<style>`,
between `/* muster:tokens:start */` and `/* muster:tokens:end */`, written there by
`node tools/tokens/sync.mjs`. `tests/ui/design-tokens.test.ts` fails if any page drifts.

**To change a token: edit `assets/tokens.css`, run `node tools/tokens/sync.mjs`, commit both.**
Editing the block inside a page is editing the wrong file; the next sync overwrites it.

Inlining rather than `<link>`ing is deliberate. Every page here is self-contained and makes
no stylesheet request; a shared linked file would add a render-blocking request to every one of them
and give them one shared way to render completely unstyled -- one bad deploy, or one CSP edit
on a new host. The cost of inlining is seven copies, and the test is what makes seven copies
safe. A new page adopts the block by having its `:root` replaced on the next sync run, and
must be added to `PAGES` in `tools/tokens/sync.mjs` and to the test.

This was adopted 2026-09-13 after the copies had already drifted silently: `--rose` was
`#f6516a` on the landing page and `#f43f5e` on the other five, `--text-muted` and `--teal-glow`
split the same way, and `--font-mono` fell back to a bare `monospace` on five of the seven pages
that existed then.
Nothing looked broken, which is the point. The landing page's `--font-body` / `--font-display`
names are kept as aliases of `--font-sans` / `--font-serif` so its existing call sites did not
have to be rewritten.

## A feature flag says where it is enforced, or it says it is enforced nowhere

`muster.feature_flags.enforcement` is a `text[]` of `sql` / `app` / `edge`. An empty
array means **no code reads this key** — and the Super Admin console renders that as a
"read by nothing" badge with both switches disabled, because a switch you can move that
changes nothing is worse than a missing one: it reports a control that does not exist.

This was added 2026-09-16 after the console had been shipping exactly that for months.
Eleven of twenty-two flags were enforced nowhere and nothing on screen said so, including
three that read as safety controls — `scheduled_scans` (pg_cron scanned regardless),
`telegram_alerts` (there is no Telegram relay in this project), and `super_admin_console`
(console access is `users.role = super_admin`, checked inside every `muster_admin_*`
function; the flag gates nothing and turning it off would not close the console). Ten
shipped surfaces had no flag at all, and `app.html` read `o.flags.white_label`, a key that
has never existed, so the white-label badge said OFF whatever the real flag was set to.

**When you add a flag:** set `enforcement` in the same migration that adds the code
reading it, never before. `muster_admin_create_flag` deliberately hard-codes `'{}'` — a
key that did not exist a minute ago is read by nothing, and the console must say so.
`tests/ui/flag-registry.test.ts` checks every claim against the repo in both directions,
including the dangerous one: a flag claiming *no* enforcement that SQL is in fact gating on
would leave the console disabling a live switch.

**`has_flag` vs `flag_state_for_org`.** `muster.has_flag(org, key)` consults the *calling
user's* overrides first — right for a tenant asking "can I do this". `muster.flag_state_for_org`
is the same minus that step, for the two jobs where a user must not enter into it: engine
paths running as `service_role` with no user at all, and the console asking what org 17
resolves to, where the answer must not change depending on which super admin is looking.

Four flags are wired as of migration `20260916022923`, all defaulting on:
`scheduled_scans` (the due-scan CTE in `muster.engine_claim`; `next_run_at` is not bumped
for a gated website, so switching it back on resumes rather than having skipped windows),
`email_alerts` (`muster_engine_claim_alerts` — the gate is on the **claim**, so off holds
already-queued alerts as `pending` rather than dropping them), `support_impersonation` and
`admin_url_scanner`. Ten remain unwired on purpose; each row carries a `wiring_note`
saying why and what would wire it. `commercial_use_enabled` can never be wired — it is a
licence term, not a code path, and must not be presented as a control.

Nav gating in `app.html` (`Live.navFlagMap` / `applyFlagsToNav`) **fails open**: a key
missing from the workspace payload leaves the nav item visible. These flags gate
visibility, not authority — the RPC behind every view enforces RLS whatever the sidebar
shows — so a partial load must not silently strip half a tenant's workspace.

## Other notes

- **`muster.partners` is the main site.** It is path-routed, not subdomain-routed: `/` is the landing
  page, `/onboarding` is `onboarding.html`, `/sitrep` is `sitrep.html`, `/sitrep/sample` is
  `sitrep-sample.html`. The older `*.muster.28footsystems.com` subdomains still resolve and are
  deliberately kept alive — magic-link emails and onboarding invites already delivered point at
  `app.muster.28footsystems.com/app`, and retiring those hosts would strand every link in the wild.
  Retire them only once nothing outstanding references them.
- **Sign-in and the workspace live on `app.muster.partners`** — `/` is `signin.html`, `/app` is
  `app.html`, `/admin` is `admin.html`, `/signin` is an alias. They are on their own host, not on `muster.partners`, and they
  are always served **together**: a Supabase session from a password sign-in is stored per-origin, so
  splitting `signin.html` and `app.html` across hosts makes sign-in appear to succeed and then the
  workspace loads signed-out. A host serves both or neither. `app.muster.28footsystems.com` still
  serves the same pair for links already in the wild.
- **`admin.html` is the standalone Super Admin Console, at `app.muster.partners/admin`.** It is on the
  app hosts, not a console host of its own, for exactly the reason `signin.html` and `app.html` are
  served together: a Supabase session is stored per-origin, so a console anywhere else loads
  signed-out for someone who just signed in. It builds a client with `detectSessionInUrl: false` --
  it never completes a sign-in, it requires one that already happened here -- and bounces to `/` when
  there is no session. **It holds no role check of its own, deliberately.** Everything it renders
  comes from one RPC, `public.muster_admin_console()` (migration `20260916023416`), which is
  `SECURITY DEFINER`, gated on `muster.is_super_admin()`, and raises `42501` for anyone else; the
  page recognises that error and shows a "not a super admin" gate. Grants match every other
  `muster_admin_*` RPC -- `authenticated` only, `anon` revoked by name.
  Two figures on it have **no instrumentation behind them and the payload says so** rather than
  guessing, and neither may be quietly replaced with a nicer number: API request volume is not
  metered anywhere in the schema (the tile reports issued/active/recently-used keys instead), and
  `revenue` is **plan-implied**, not billed -- nothing reads Stripe invoices, and
  `customer.subscription.deleted` is unhandled, so a cancelled customer prices in until their plan
  is changed by hand. Four nav sections (Workspaces, AI Readiness, Domain Monitor, Reports) render
  an explicit "not instrumented" panel naming what would have to exist first, because the schema
  cannot answer them; if you build one of those, replace the stub, don't fill it with a plausible
  table. This console is *additional to*, not a replacement for, `app.html`'s in-app `superadmin`
  view, which still backs `muster_admin_overview()` and owns the write actions (plan changes,
  impersonation, URL runner, incident triage). `app.html`'s super admin hero links across to it.
- `signin.html` derives its redirect target as `window.location.origin + '/app'` rather than
  hardcoding a host, so it is same-origin on whichever app host served it. It must stay **absolute**:
  it is passed to `signInWithOtp` as `emailRedirectTo`, which Supabase requires to be a full URL —
  and that URL has to be on the Supabase project's allowed-redirect list or magic links fail.
- `index.html` = public landing page (`muster.partners`, and `muster.28footsystems.com`). Its two workspace CTAs link to
  `app.muster.partners/` (root) — `signin.html`, a real, dedicated sign-in page (email + magic
  link, or email + password), not a modal, and not straight into the workspace SPA. The workspace SPA
  (`app.html`) itself lives at `app.muster.partners/app`, not at that host's root — an
  already-authenticated redirect (from `signin.html`, a magic-link email, or `onboarding.html`'s
  "Go to your workspace" links) must land on `/app`, never on `/` (root just shows the sign-in page
  again, session or not). `signin.html` shares its Supabase session origin with `app.html` (same host)
  so a password sign-in there persists correctly when it redirects to `/app`; a magic-link email lands
  the user directly on `/app` regardless of what origin sent it. Signup is intentionally absent from
  `signin.html` (self-serve is paused, see below) — it links to the same sales contact instead, plus a
  "continue with demo data" link straight to `/app` for anyone not signing in. `/signin` also still
  resolves to `signin.html` (kept as an alias, in `middleware.js`) alongside the root. `app.html` still
  has its own in-app sign-in modal (`Live.openAuth()`) for anyone who lands on `/app` directly without a
  session; don't remove it when touching `signin.html`. `sitrep.html` = a signed-in, tenant-scoped SITREP viewer
  (`muster.partners/sitrep`, or `sitrep.muster.28footsystems.com`) — reuses the same Supabase Auth session and `public.muster_*` RPCs
  as `app.html`; RLS decides what each signed-in user can see, same as everywhere else. It is real data,
  not a demo. `sitrep-sample.html` (`muster.partners/sitrep/sample`, or `sitrep.muster.28footsystems.com/sample`) is the **one remaining**
  static, no-auth, fictional SITREP covering every finding category and severity — a reference/sales
  asset, not real data.
- `onboarding.html` (`muster.partners/onboarding`, or `onboarding.muster.28footsystems.com`) is the **real**, server-enforced guided
  onboarding wizard for a paid client provisioned via `muster.onboard_client()` (Stripe checkout ->
  Supabase Auth invite -> this page). It is not a demo and has no local/client-side state machine: every
  gate lives in Postgres (`muster.onboarding_steps`, `public.muster_onboarding_state()`,
  `public.muster_onboarding_complete_step()`) — the page just renders whichever step the backend says is
  current and posts back to it. See `supabase/migrations-shared-project/20260906063133_muster_guided_onboarding.sql`
  (as originally applied) and `20260906064403_muster_onboarding_fixes.sql` (a security-grant hardening
  pass plus two validation fixes found on review — read the latter's header comment before touching this
  system again). `onboard_client()` itself is not wired to anything live and is not going to be: it is
  documented dead and buggy (see migration `20260906012143`'s header), and the self-serve path
  deliberately does not use it. This page is reachable today via a manually issued Supabase Auth invite
  against an org seeded by `muster.onboarding_seed()`.
- **Self-serve billing does not go through `onboard_client()`.** `muster-stripe-webhook` is built,
  deployed and tested: it verifies the Stripe signature, gates on `payment_status`, invites the auth
  user, and records a pending grant keyed by email via `muster_engine_record_commercial_grant`. The
  existing onboarding wizard (`muster_onboard` -> `muster.do_onboard`) claims that grant when the buyer
  creates their organization, upgrading it off `trial` and marking the grant applied so a second org
  cannot claim it. That handoff is verified against the live database, not assumed. The pure half of
  the webhook lives in `core.ts` under `tests/billing/stripe-webhook.test.ts`; the I/O half is in
  `index.ts`. What remains is Stripe dashboard configuration only: the endpoint registered against the
  **new** project's function URL, `STRIPE_WEBHOOK_SECRET` set, and `tier` + `stage` metadata on each
  Payment Link. A link without that metadata is rejected 400 -- check it first if a real checkout fails.
  Subscription **cancellation is not handled**: nothing consumes `customer.subscription.deleted`, so a
  cancelled customer keeps their plan until someone changes it by hand.
- A super admin can also run a real scan against any URL from `app.html`'s admin console ("Run a URL
  scan") and get back real findings from the live engine — see `muster_admin_run_url` /
  `muster_admin_website_overview` / `muster_admin_url_runs` in
  `supabase/migrations-shared-project/20260906062134_muster_admin_url_runner.sql`. Ad-hoc URLs run this way are parked
  in a dedicated internal sandbox org (`organizations.is_admin_sandbox`), never in a real tenant's risk
  register. This is separate from the guided onboarding flow above and from `sitrep-sample.html` — three
  different tools for three different jobs, not competing demos.
- **Security headers come from `middleware.js`, on every response.** `SECURITY_HEADERS` (CSP,
  X-Frame-Options, nosniff, Referrer-Policy, Permissions-Policy) is applied through `secureRewrite()`
  and `secureNext()`; there is deliberately no bare `rewrite()` or `next()` left in the file, so a new
  branch cannot forget them. HSTS is **not** set there — Vercel already sends it on these domains, and
  two sources for one header is how they drift. The CSP still carries `'unsafe-inline'` on `script-src`
  because all six pages ship an inline `<script>`; extracting those is the prerequisite for tightening
  it, and `tests/routing/middleware.test.ts` asserts the current state so the change has to be
  deliberate. Any new external origin a page loads must be added to the CSP or it is silently blocked.
- `/privacy` is `privacy.html` on `muster.partners`. `/robots.txt`, `/sitemap.xml` and
  `/.well-known/security.txt` are real files at the repo root; `/.well-known/` and `/sitemap.xml` are
  shared across every host (like `/assets/`) so a researcher on an app host finds the disclosure policy
  rather than a login page, and the app hosts serve `robots-app.txt` instead, which disallows
  everything. `security.txt` has a hard `Expires:` date — renew it before it lapses, because an expired
  one counts as no policy.
- Host and path routing is handled by `middleware.js` (Vercel Routing Middleware, using `@vercel/functions`).
  `vercel.json`'s declarative `rewrites`/`has` cannot branch on the Host header — only real code can — so
  don't reintroduce host-conditional `vercel.json` rewrites for new hosts; add another `if (host === ...)`
  branch to `middleware.js` instead. Path matching goes through `isUnder(path, base)` so `/sitrep/sample`
  matches the `/sitrep` family while `/sitrepfoo` does not, and `normalize()` strips trailing slashes.
  There is no `vercel.json` in this repo; don't add one for routing.
- Migration files are named after the version `apply_migration` actually assigned, not after
  when you wrote them — the tool assigns the version from its own clock and ignores the filename.
  After applying, read the version back and name the file that. See
  `supabase/migrations/README.md` for the rule and
  `supabase/migrations-shared-project/README.md` for the war story; getting this wrong left 16
  forward references and four applied migrations with no file, three of which were the cron
  schedules.
- **Auth wiring is verified by `muster-auth-smoke`, not by reading the dashboard.** That edge
  function mints a real recovery link with the service-role key, follows it, sets a password and
  signs in with it, and probes the redirect allowlist with a deliberately invalid token plus a
  host that must be rejected. It returns booleans and redacted origins only -- never a token,
  link or password. `rotate_password` defaults to false and can only ever target the pinned QA
  sentinel account. Invocation and the 2026-09-09 results are in `docs/EMAIL.md`. Outstanding
  after that run: **Site URL on `hjowfnzpomzxazmzywxw` must be on the app host** -- the chosen
  value is `https://app.muster.partners` (see `docs/EMAIL.md` for why the root rather than
  `/app`). **It was believed changed on 2026-09-13 and it is not: on 2026-09-15 a real magiclink
  again landed on `https://www.muster.partners/` with live tokens in the fragment.** That is a
  dashboard setting; nothing in this repo can change it, and nothing in this repo can verify it
  either except `muster-auth-smoke` plus an actual link. Do not mark it done from a note. Also outstanding: none of the six auth email
  templates have been pasted from `supabase/auth-email-templates/` -- bodies and subjects are
  still GoTrue stock.
- **Only the pages that complete a sign-in may consume an auth fragment.** `detectSessionInUrl`
  defaults to **true**, so a page that builds a Supabase client for any other reason will parse
  and consume the `#access_token=...` of any auth link that reaches it. Auth links are single
  use, so that silently burns them. `app.html`, `signin.html`, `sitrep.html` and
  `onboarding.html` each legitimately need it on (magic link, recovery, or an invite link).
  `index.html` builds a client only to call `muster_public_pricing` and now passes
  `detectSessionInUrl: false`, and `admin.html` does the same for the same reason; `privacy.html` and `sitrep-sample.html` build none at all. A new
  page that adds a client for data must turn it off explicitly.
- **`index.html` forwards a stray auth fragment; it does not swallow it.** Declining to consume
  the fragment (above) keeps the tokens alive but leaves the user on marketing copy holding a
  session no page will take. So a head-level script in `index.html` runs before paint and
  `location.replace()`s any fragment carrying `access_token`, `refresh_token`, `error_code` or
  `error_description` to `https://app.muster.partners/`, fragment intact. Root, not `/app`:
  `signin.html` handles a live session, `type=recovery` and an expired link; `app.html` would
  drop a recovery session into the workspace with no password form. `tests/auth/landing-auth-fragment.test.ts`
  pins the behaviour and, more importantly, the negatives -- an in-page anchor like `#pricing`
  must never redirect, and the forwarder must not be able to loop onto its own origin. This is
  a mitigation for a wrong Site URL, not a substitute for fixing it.
- **`app_metadata.force_password_change` is enforced in Postgres, not in a page.** Migration
  `20260915230805` added `muster.password_change_required()` -- a predicate over the caller's own
  JWT claims -- and wired it into the authorization spine (`current_user_id`, `is_super_admin`,
  `org_role`, `shares_org_with`, `onboarding_caller`, `ensure_user_from_auth`). A flagged caller
  resolves to no role anywhere, so tenant RPCs raise `42501` and RLS answers empty. Before that,
  nothing in the entire stack read the flag: it sat on a live `super_admin` account that signed in
  on the old password and went straight to the workspace. Clearing it needs the service role, so it
  goes through the **`muster-set-password`** edge function, which sets the password and clears the
  flag in ONE admin call -- never add a separate "clear the flag" endpoint, that is a bypass with
  extra steps. After a successful change the browser **must** call `refreshSession()`: claims are
  minted at sign-in and not read live, so the old token still says `true` and the workspace looks
  broken until it is replaced. `signin.html` owns the form and checks the flag **before** its bounce
  to `/app`; `app.html` and `admin.html` send a flagged session back to `/` -- `admin.html`
  before its first RPC, because it renders a `42501` as "access denied" and that is the wrong
  answer for a super admin whose only problem is an old password. That ordering is the only thing
  keeping the two from looping, and `tests/auth/set-password.test.ts` asserts it. Password policy is
  12 characters, no composition rules, blocklist checked against the padded stem too; it lives in
  that function's `core.ts`. Break-glass and the full rationale are in `docs/BACKEND.md` and the
  migration header.
- **Every new `public.muster_engine_*` function must REVOKE from `anon, authenticated` by name.**
  Supabase ships default privileges that GRANT EXECUTE on every new function in the `public`
  schema to both roles. `revoke all ... from public` does **not** undo that -- `PUBLIC` the
  pseudo-role and `anon`/`authenticated` the real roles are different grantees -- so a new
  engine RPC is callable with the publishable key, which ships in page source, from the moment
  it is created. Engine RPCs are called only by edge functions holding
  `SUPABASE_SERVICE_ROLE_KEY`; none should ever be reachable by a browser. This was found live
  on 2026-09-13: `muster_engine_record_email_event` and `muster_engine_resolve_alert` were both
  anon-executable, which let anyone mark a pending `notification_outbox` row `sent` and suppress
  a real HIGH-risk alert before it was emailed. Fixed in migrations `20260913150857` and
  `20260913150920` -- and the first of those created a new function with the same defect, which
  is how sure the default is. Verify with the ACL query in that migration's header, then prove
  it with an actual anon call: a revoked function answers `401 / 42501 permission denied`.
- **The watchdog closes what it opens.** `muster-watchdog` calls
  `muster_engine_close_cleared_incidents(source, evidence)` when a check comes back clear, so a
  condition that resolves itself closes its own incident. Before 2026-09-13 nothing could ever
  close one: `engine_error_spike` is fingerprinted by date while its check is a rolling 24-hour
  window, so one failed scan on 2026-09-08 left two incidents open forever and bumped them 144
  times. Open-incident count is only a usable signal while it can go down. A new check that
  reports an incident needs a matching close path, or it is a counter, not an alarm.
- **Frameworks are data, in `muster.frameworks`; adding one is an insert, not a constraint edit.**
  `controls.framework` is a foreign key to that table and `muster.framework_label()` reads it, so a
  new framework needs one row (key + display label) and nothing else. Before 2026-09-16 the valid
  set was a hardcoded `CHECK` on a `varchar(16)` column, and the AI-governance rules broke the whole
  control register for an hour by introducing a 30-character key: `sync_controls` threw 22001,
  `muster_045` swallowed it into an `activity_events` row by design, and the register silently went
  stale. `muster-watchdog` now opens a `control_register_failure` incident on that activity row and
  closes it when the count returns to zero, because a deliberately swallowed error needs a watcher
  or it is just a silent error.
- **A framework mapping is a citation, not a test, and the distinction is the product's integrity.**
  `scan_rules.framework_refs` maps rules to NIST CSF 2.0 and 1.1, NIST SP 800-53 Rev. 5, OWASP Top
  10:2025, OWASP Secure Headers, SOC 2 (AICPA TSC), ISO 27001, PCI DSS, GDPR and WCAG. Citing
  `A02:2025` says a finding belongs to that category; it never says MUSTER tests the category. The
  engine is HTTP-native with no browser and no authenticated crawl, so most of the Top 10 is out of
  reach by construction. **Never describe MUSTER as providing a SOC 2 opinion** -- that is a licensed
  CPA firm's examination. MUSTER produces evidence for one and readiness signal between them; route
  the attestation question to the client's auditor. Full table and the deliberate ASVS omission are
  in `docs/SCAN-RULES.md`.
- **A scan rule stays inactive until the engine that emits it is deployed.** Not tidiness: an
  active rule the engine never evaluates has no findings by construction, and `sync_controls()`
  scores a reference with no open findings as **met** -- so the register reports a check that was
  never run as passed. `SEC-014`, `SEC-015` and `EMAIL-008` are held inactive by migration
  `20260916210100` for exactly this reason; the activation statement is in its header and in
  `docs/SCAN-RULES.md`. Same rule as feature-flag `enforcement`: never declare a thing enabled
  before the code reading it exists.
- **Edge functions deploy from CI, not from a paste.** `.github/workflows/deploy-functions.yml`
  runs `supabase functions deploy` on merge to main for anything under `supabase/functions/`. It
  skips with a notice, rather than failing, until the `SUPABASE_ACCESS_TOKEN` repository secret is
  set. Before this, every function in the project was deployed by pasting its source through a chat
  tool, which is fine at 7 KB and stops being fine at `muster-scan`'s 38 KB across three files: the
  paste becomes the risk, and a silent transcription slip ships a broken scanner with no diff to
  review. Migrations are deliberately **not** in that workflow -- their files are named after the
  version `apply_migration` assigned, which a `db push` would not reproduce.
- **Email routing is two separate paths and must not be conflated** — see `docs/EMAIL.md`.
  Magic link, invite, signup confirm, email change, password reset and reauthentication are sent
  by **Supabase Auth (GoTrue)**, not by this codebase, and reach Resend only because Resend is
  configured as Supabase's SMTP relay. Their templates live in Supabase project config, sourced
  from `supabase/auth-email-templates/` — edit the files there first, then paste into the
  dashboard. A Resend *template* can never render them. Application email (currently only the
  `risk_opened` alert) is the other path: `muster-alert-dispatch` calls Resend's REST API
  directly. Auth config does not migrate between Supabase projects; it has to be set on each.
  `/reset` on the app hosts is the password-recovery landing and is served by `signin.html`
  through middleware's catch-all — it has no page of its own, and it must be on the Supabase
  project's allowed redirect list or GoTrue silently substitutes Site URL.
- **Backend: Supabase project `hjowfnzpomzxazmzywxw`, schema `muster`.** MUSTER has its own project
  now; `supabase/config.toml` and all five frontend pages point at it, and `supabase/migrations/` is its
  history. Real scan engine, SITREP generation, RLS, and RPCs are live — see `docs/BACKEND.md`.
- **The old shared 28FS project `mgtmqucaldkaxvxglguw` no longer runs any part of MUSTER**, as of
  2026-09-08. Its five `muster-*` cron jobs are unscheduled (not merely inactive), its last MUSTER
  write was 2026-09-07 20:27 UTC, and both MUSTER API keys are revoked. What is still there: the
  `muster` schema (45 tables, 58 functions), the 70 `public.muster_*` shims, and 8 deployed edge
  functions, all dormant. Removing them needs the Supabase CLI — the MCP has no delete for edge
  functions — and is tracked in `supabase/migrations/MUSTER-PROJECT-LEDGER.md`.
  **That project is shared and very much alive for other brands: 334 edge functions, 107 cron jobs,
  and 14 `auth.users` of which only 3 are MUSTER's.** Anything done there must be surgical and must
  assert the other-brand counts before and after. `auth.users` must never be touched, not even
  MUSTER's three rows, because `anthony@28footmarketing.com` is the owner account for the other
  brands too. MUSTER's 48 migrations against it stay as history in
  `supabase/migrations-shared-project/` — a readable history, not a replayable one. Do not add to it.
- **Stripe self-serve is fully configured and verified** (2026-09-08), against
  `acct_1PUDj1JijfcmbDDB`: both Payment Links carry `tier` and `stage` metadata, the
  `checkout.session.completed` endpoint points at the new project, and `STRIPE_WEBHOOK_SECRET` and
  `RESEND_API_KEY` are both set — each proven by observed behaviour, not by reading a checklist.
  Do not repeat "Stripe is outstanding" from an older note. What IS outstanding: GoTrue SMTP,
  templates and rate limit on the new project, and `customer.subscription.deleted`, which nothing
  consumes.
