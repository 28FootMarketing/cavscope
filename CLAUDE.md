# MUSTER — standing rules for this repo

## Tooltips are mandatory on every page

Every page in this repo (`index.html`, `app.html`, `onboarding.html`, and any future page) must have
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
  (`app.muster.28footsystems.com`). `onboarding.html` = a **simulated** sales-demo onboarding wizard
  (`onboarding.muster.28footsystems.com`) — its pre-flight scan and generated credentials are scripted,
  not wired to the real Supabase backend. `sitrep.html` = a signed-in, tenant-scoped SITREP viewer
  (`sitrep.muster.28footsystems.com`) — reuses the same Supabase Auth session and `public.muster_*` RPCs
  as `app.html`; RLS decides what each signed-in user can see, same as everywhere else. It is real data,
  not a demo. `sitrep-sample.html` (`sitrep.muster.28footsystems.com/sample`) is a static, no-auth,
  fictional SITREP covering every finding category and severity — a reference/sales asset, not real data.
- Subdomain routing is handled by `middleware.js` (Vercel Routing Middleware, using `@vercel/functions`).
  `vercel.json`'s declarative `rewrites`/`has` cannot branch on the Host header — only real code can — so
  don't reintroduce host-conditional `vercel.json` rewrites for new subdomains; add another `if (host === ...)`
  branch to `middleware.js` instead.
- Backend: dedicated Supabase project `hjowfnzpomzxazmzywxw` ("Muster"), schema `muster`. Real scan engine,
  SITREP generation, RLS, and RPCs are already live — see `docs/BACKEND.md`. This project superseded the
  original build on the shared `mgtmqucaldkaxvxglguw` ("28 Foot Systems") project as of 2026-09-16; that
  shared project still has an active `muster-scan-due-15min` cron job and its own diverged muster data and
  must not be treated as a second source of truth — confirm with Anthony before writing to it again, and see
  the decommission note in `docs/BACKEND.md`.
