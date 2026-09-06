# MUSTER — standing rules for this repo

## Tooltips are mandatory on every page

Every page in this repo (`index.html`, `app.html`, `sitrep.html`, `sitrep-sample.html`, and any future page) must have
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
- `onboarding.html` is a **retired** simulated sales-demo onboarding wizard — its pre-flight scan and
  generated credentials were scripted, never wired to the real Supabase backend. The
  `onboarding.muster.28footsystems.com` subdomain now redirects to `sitrep-sample.html` (see
  `middleware.js`) instead of serving it, so there is only one demo surface in the funnel. The file is
  kept in the repo, unlinked, in case it's revived; don't route new traffic to it. In its place, a super
  admin can run a real scan against any URL from `app.html`'s admin console ("Run a URL scan") and get
  back real findings from the live engine — see `muster_admin_run_url` / `muster_admin_website_overview`
  / `muster_admin_url_runs` in `supabase/migrations/20260908050000_muster_admin_url_runner.sql`. Ad-hoc
  URLs run this way are parked in a dedicated internal sandbox org (`organizations.is_admin_sandbox`),
  never in a real tenant's risk register.
- Subdomain routing is handled by `middleware.js` (Vercel Routing Middleware, using `@vercel/functions`).
  `vercel.json`'s declarative `rewrites`/`has` cannot branch on the Host header — only real code can — so
  don't reintroduce host-conditional `vercel.json` rewrites for new subdomains; add another `if (host === ...)`
  branch to `middleware.js` instead.
- Backend: Supabase project `mgtmqucaldkaxvxglguw`, schema `muster`. Real scan engine, SITREP generation,
  RLS, and RPCs are already live — see `docs/BACKEND.md`.
