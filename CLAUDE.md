# MUSTER — standing rules for this repo

## Tooltips are mandatory on every page

Every page in this repo (`index.html`, `app.html`, `onboarding.html`, `sitrep.html`, `sitrep-sample.html`, and any future page) must have
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

- `index.html` = public landing page (`muster.28footsystems.com`). `app.html` = the real workspace
  (`app.muster.28footsystems.com`). `sitrep.html` = a signed-in, tenant-scoped SITREP viewer
  (`sitrep.muster.28footsystems.com`) — reuses the same Supabase Auth session and `public.muster_*` RPCs
  as `app.html`; RLS decides what each signed-in user can see, same as everywhere else. It is real data,
  not a demo. `sitrep-sample.html` (`sitrep.muster.28footsystems.com/sample`) is the **one remaining**
  static, no-auth, fictional SITREP covering every finding category and severity — a reference/sales
  asset, not real data.
- `onboarding.html` (`onboarding.muster.28footsystems.com`) is the **real**, server-enforced guided
  onboarding wizard for a paid client provisioned via `muster.onboard_client()` (Stripe checkout ->
  Supabase Auth invite -> this page). It is not a demo and has no local/client-side state machine: every
  gate lives in Postgres (`muster.onboarding_steps`, `public.muster_onboarding_state()`,
  `public.muster_onboarding_complete_step()`) — the page just renders whichever step the backend says is
  current and posts back to it. See `supabase/migrations/20260908055000_muster_guided_onboarding.sql`
  (as originally applied) and `20260908060000_muster_onboarding_fixes.sql` (a security-grant hardening
  pass plus two validation fixes found on review — read the latter's header comment before touching this
  system again). `onboard_client()` itself is not yet wired to anything live: the `muster-onboard` Stripe
  webhook that's meant to call it hasn't been built, so this page is only reachable today via a manually
  issued Supabase Auth invite against an org seeded by `muster.onboarding_seed()`.
- A super admin can also run a real scan against any URL from `app.html`'s admin console ("Run a URL
  scan") and get back real findings from the live engine — see `muster_admin_run_url` /
  `muster_admin_website_overview` / `muster_admin_url_runs` in
  `supabase/migrations/20260908050000_muster_admin_url_runner.sql`. Ad-hoc URLs run this way are parked
  in a dedicated internal sandbox org (`organizations.is_admin_sandbox`), never in a real tenant's risk
  register. This is separate from the guided onboarding flow above and from `sitrep-sample.html` — three
  different tools for three different jobs, not competing demos.
- Subdomain routing is handled by `middleware.js` (Vercel Routing Middleware, using `@vercel/functions`).
  `vercel.json`'s declarative `rewrites`/`has` cannot branch on the Host header — only real code can — so
  don't reintroduce host-conditional `vercel.json` rewrites for new subdomains; add another `if (host === ...)`
  branch to `middleware.js` instead.
- Backend: Supabase project `mgtmqucaldkaxvxglguw`, schema `muster`. Real scan engine, SITREP generation,
  RLS, and RPCs are already live — see `docs/BACKEND.md`.
