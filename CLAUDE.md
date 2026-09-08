# MUSTER — standing rules for this repo

## Tooltips are mandatory on every page

Every page in this repo (`index.html`, `app.html`, `signin.html`, `onboarding.html`, `sitrep.html`, `sitrep-sample.html`, and any future page) must have
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

## Other notes

- **`muster.partners` is the main site.** It is path-routed, not subdomain-routed: `/` is the landing
  page, `/onboarding` is `onboarding.html`, `/sitrep` is `sitrep.html`, `/sitrep/sample` is
  `sitrep-sample.html`. The older `*.muster.28footsystems.com` subdomains still resolve and are
  deliberately kept alive — magic-link emails and onboarding invites already delivered point at
  `app.muster.28footsystems.com/app`, and retiring those hosts would strand every link in the wild.
  Retire them only once nothing outstanding references them.
- **Sign-in and the workspace live on `app.muster.partners`** — `/` is `signin.html`, `/app` is
  `app.html`, `/signin` is an alias. They are on their own host, not on `muster.partners`, and they
  are always served **together**: a Supabase session from a password sign-in is stored per-origin, so
  splitting `signin.html` and `app.html` across hosts makes sign-in appear to succeed and then the
  workspace loads signed-out. A host serves both or neither. `app.muster.28footsystems.com` still
  serves the same pair for links already in the wild.
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
  system again). `onboard_client()` itself is not yet wired to anything live: the `muster-onboard` Stripe
  webhook that's meant to call it hasn't been built, so this page is only reachable today via a manually
  issued Supabase Auth invite against an org seeded by `muster.onboarding_seed()`.
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
- **The old shared 28FS project `mgtmqucaldkaxvxglguw` is still running MUSTER in production** until the
  rest of cutover lands. Its edge functions are byte-identical to the new project's, and MUSTER's 48
  migrations against it are kept as history in `supabase/migrations-shared-project/` — a readable
  history, not a replayable one. Do not add to that directory. What is still outstanding on the new
  project (auth users, secrets, GoTrue config, Stripe webhook, cron activation) is tracked in
  `supabase/migrations/MUSTER-PROJECT-LEDGER.md`.
