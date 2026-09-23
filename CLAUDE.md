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
- **A `data-tooltip` only reaches a keyboard or screen-reader user if the element it sits on is
  focusable.** The engine shows on `focusin` as well as `mouseover`, but a plain `<span>`, `<div>`,
  `<td>`, `<p>`, `<h2>`, `<aside>`, `<summary>` or `<footer>` is not part of the tab order on its
  own, so tabbing through the page skips straight over it. An end-to-end keyboard sweep on
  2026-09-23 found 148 such elements across every page except `signin.html` — a defect nothing
  caught because every existing test read the source for the attribute's presence, not for whether
  the tag carrying it could ever receive focus, and because a page like `admin.html` never
  render-completes without a live Supabase client, so a browser-only check that only inspects the
  DOM after load never sees the template-generated rows that carried most of them. **A new
  `data-tooltip` on a non-interactive tag needs `tabindex="0"`** unless the element is genuinely
  `disabled` (correctly out of the tab order regardless) or it is a `<label for="...">` — there,
  move the tooltip onto the labelled control itself (see `signin.html`'s inputs, or `sitrep.html`'s
  `authEmail`/`authPassword` fields after the fix) rather than adding a redundant tab stop right
  before it. `tests/ui/tooltip-reachability.test.ts` pins this by scanning every page's raw source,
  including inside template-literal-generated rows, for exactly that shape.

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

**As of 2026-09-17 there are 35 flags: 25 wired, 10 enforced nowhere.** Read that from
`muster.feature_flags`, not from here -- this paragraph said "four are wired" until the count
was checked, by which point it was 25, and the registry had grown from 22 keys to 35. The
`enforcement` column is the answer; a number written in prose is a snapshot that rots.

The four wired first, by migration `20260916022923`, are still the ones whose behaviour is worth
knowing: `scheduled_scans` (the due-scan CTE in `muster.engine_claim`; `next_run_at` is not
bumped for a gated website, so switching it back on resumes rather than having skipped windows),
`email_alerts` (`muster_engine_claim_alerts` — the gate is on the **claim**, so off holds
already-queued alerts as `pending` rather than dropping them), `support_impersonation` and
`admin_url_scanner`.

Each of the ten unwired rows carries a `wiring_note` saying why and what would wire it.
`commercial_use_enabled` can never be wired — it is a licence term, not a code path, and must
not be presented as a control. **One of the ten is a commercial problem rather than a deferred
feature:** `client_management_enabled` is sold on the Partner tier and its own note says the
client-org creation path does not check it, so a lower tier gets it free.

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
- **`admin.html` is the Super Admin Console, the only one, at `app.muster.partners/admin`.** It is on the
  app hosts, not a console host of its own, for exactly the reason `signin.html` and `app.html` are
  served together: a Supabase session is stored per-origin, so a console anywhere else loads
  signed-out for someone who just signed in. It builds a client with `detectSessionInUrl: false` --
  it never completes a sign-in, it requires one that already happened here -- and bounces to `/` when
  there is no session. **It holds no role check of its own, deliberately.** Its backbone is
  one RPC, `public.muster_admin_console()` (migration `20260916023416`), which is
  `SECURITY DEFINER`, gated on `muster.is_super_admin()`, and raises `42501` for anyone else; the
  page recognises that error and shows a "not a super admin" gate. Grants match every other
  `muster_admin_*` RPC -- `authenticated` only, `anon` revoked by name.
  Two figures on it have **no instrumentation behind them and the payload says so** rather than
  guessing, and neither may be quietly replaced with a nicer number: API request volume is not
  metered anywhere in the schema (the tile reports issued/active/recently-used keys instead), and
  `revenue` is **plan-implied**, not billed -- nothing reads Stripe invoices, and
  `customer.subscription.deleted` is unhandled, so a cancelled customer prices in until their plan
  is changed by hand. Three nav sections (Workspaces, AI Readiness, Domain Monitor) render
  an explicit "not instrumented" panel naming what would have to exist first, because the schema
  cannot answer them; if you build one of those, replace the stub, don't fill it with a plausible
  table. **Reports stopped being one of them on 2026-09-17**, backed by
  `muster_admin_sitreps()` and `muster_admin_sitrep()` (migration `20260917070953`): an index
  across every tenant, and the report body fetched only for the one opened, because `content_md`
  is a few KB each. The markdown is rendered **verbatim in a `<pre>`, never parsed** -- so the
  console cannot disagree with what the tenant reads at `/sitrep`, and so a hand-rolled renderer
  over report content does not become an injection bug in the page that reports on other people's
  security.
  **It is the only super admin console, as of 2026-09-23.** Until then `app.html` carried a second
  one, a `superadmin` view that owned every write (plans, roles, incident triage, pricing stage and
  tier visibility, the flag registry, support impersonation, an ad-hoc URL runner) while this page
  owned reports and the audit runner. Two consoles over different RPCs disagreed in ways nobody had
  checked: that view's "platform-wide" white-label switch changed only local page state, its demo
  copy advertised a Puppeteer/Playwright crawler the engine has never had, and this page read a
  missing pricing `visible` key as "shown" while `index.html` correctly showed Partner alone. Every
  one of those writes now lives here, as a form over the same `SECURITY DEFINER` RPC, and
  `tests/ui/one-admin-console.test.ts` fails if `app.html` calls a `muster_admin_*` RPC again --
  **except `muster_admin_tenant`**, because entering a tenant's workspace is `app.html`'s job. This
  page links to it as `/app#tenant=<id>`.
  **What `app.html` does with a super admin now.** Its old view is `teamSettings` ("Team &
  Settings"): team, invitations, API keys, report branding and the tenant's own LLM, which is
  everything a tenant manages for itself and nothing platform-wide. A super admin sees a
  "Platform Console" nav link and topbar button, both shipped `hidden` and shown only once
  `muster_my_workspace` says `is_super_admin`. A super admin arriving at `/app` with **no fragment**
  is sent here, once per page load; `#tenant=<id>` opens that tenant, and any other fragment keeps
  them in the app -- which is why this page's "MUSTER" link is `/app#overview`, not `/app`, or it
  would bounce straight back.
  **Beyond the console payload it makes five side reads** (`SIDE_READS`): the flag registry,
  impersonation status and log, `muster_admin_platform_extras()` (platform agents and the
  jurisdiction review queue -- built in migration 068 for this page and never wired until now), and
  `muster_admin_overview()`, kept **only** for its `incidents` list, because triage needs incident
  ids and the console payload reduces them to counts. Each settles on its own: one failing blanks its
  own panel and says so, never the page. After every write the page re-reads, on failure too, so a
  select or switch the database refused snaps back to what is true. Changes that reach someone other
  than the person clicking -- a tenant's plan, a user's role, the public pricing stage, a flag's
  default, a kill switch, revoking an override, deleting a flag -- confirm first; a focused `<select>`
  fires `change` on an arrow key in some browsers, so an unconfirmed one is a keypress from a write.
  **The Audit Queue could start a scan first, from 2026-09-17**, while the rest of the page was
  still a single read. Running an audit earned its place here because this is the
  page you are already on when you notice a site needs one, and sending someone to another host to
  press a button is how a console stops being used. It adds **no RPC**: the ad-hoc field calls
  `muster_admin_run_url` (super admin, flag `admin_url_scanner`, target parked in the sandbox org)
  and the site dropdown calls `muster_request_scan` (flag `manual_scans` for that org). Both are
  `SECURITY DEFINER` and check the caller themselves, so the panel is a form, not a gate --
  `muster.org_role()` returns `super_admin` for every org, which is why a super admin can re-audit
  a tenant site they are not a member of. Re-auditing a real customer site prompts first, because
  it writes to their register and can move their posture score; the sandbox scan does not, because
  that org is nobody's data. `tests/ui/audit-runner.test.ts` pins both of those, and the two
  failure modes below.
  **A scan is queued, not finished, when the RPC returns.** `do_request_scan` fires the engine
  through `net.http_post`, which pg_net hands to a background worker before returning, so the
  engine starts a few hundred milliseconds later. Reading the result immediately shows a queued
  scan with no findings, which is exactly what "the audit did not populate" turned out to be in
  `app.html`. Both paths poll `muster_scans` to a terminal status, with a bounded number of tries
  so a hung engine does not spin forever, and a `failed` scan is reported as failed rather than
  done -- it produces no findings, so the site keeps its previous score, and calling that complete
  would claim a check that never ran.
  **Its form fields are held in state, not only in the DOM.** `render()` replaces the whole page
  and the panel re-renders on every status update, so a value living only in a node would be
  blanked mid-scan with the URL you typed still being scanned. The same holds for every form on the
  page: the support form keeps `impForm`, and the flag override and new-flag forms keep `drafts`,
  dropped only after a save succeeds so a refused one (a duplicate key) comes back as typed. Those
  two lived in the DOM alone until 2026-09-23 and a search keystroke emptied them. A new form here
  gets the same treatment or it has the same bug.
  **And it links to the report.** A scan writes a SITREP about a second after it finishes, and for
  a day it wrote one that nothing in the product pointed at -- an audit was run, the Reports
  section was a stub, and the report sat unread in `muster.sitreps`. The runner now resolves the
  SITREP **by `scan_id`**, not by taking the newest row, because two audits started close together
  would otherwise each link to whichever finished last.
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
- **`tools/local-scan/` is a fourth way to get findings, and the only one that writes nothing.**
  `npm run scan:local -- https://example.com` runs the real engine's rule code against a URL with no
  database, no service-role key and no tenant, then prints the findings and a posture score and exits
  non-zero on any `critical` or `high`. Use it for triage, for CI, or from a machine with no keys; use
  the admin console's "Run a URL scan" when the result should be recorded. It is an **adapter** over
  `supabase/functions/muster-scan/index.ts` — it reads that file and strips the Supabase client, the two
  `muster_engine_*` RPCs and `Deno.serve()`, asserting each cut — so there is still exactly one copy of
  the rule set. The one thing duplicated is the posture weights, copied from
  `20260907223344_muster_012_helper_functions_sql.sql` into `tools/local-scan/score.mjs`; change one and
  you must change the other. `tests/scan/local-scan.test.ts` pins the adapter and scans a local server
  end to end.
- **Rule logic that can be pure belongs in a sibling module with tests, not inline in `runScan()`.**
  `supabase/functions/muster-scan/html.ts` is that module today: `stripTags`, `stripToBodyText` and
  `detectClientRendered`, pinned by `tests/scan/html.test.ts`, alongside `email-auth.ts` and its own
  tests. The client-rendered check lived inline until 2026-09-15 and shipped a defect nothing could
  catch: it measured "visible text" that still included the `<title>` and the tail of any comment whose
  prose contained a `>` (because `stripTags`'s `<[^>]*>` ends at that first `>`). A Vite SPA shell whose
  real body was `<div id="root"></div>` measured 411 characters against the 200 threshold, so the engine
  called it server-rendered and reported `PRIV-001` at **medium severity and medium confidence with no
  caveat** on a page it had never read. That is the same class of failure as telling a client they are
  covered when they are not, pointed the other way. Issues #93 and #94; engine `http-native-1.3.0`.
  **`ENGINE_VERSION` moves whenever rule output changes**, because a finding's severity is only
  comparable across scans on the same version. **Read the current value on `main` before picking the
  next one, not the value your branch started from.** This change was written as `1.2.0` and had to
  become `1.3.0` on merge: `SEC-014`/`SEC-015`/`EMAIL-008` (#103) took `1.2.0` while the branch was
  open, and two long-lived branches each bumping the minor from the same base is the ordinary case,
  not a freak one. Landing both as `1.2.0` would have put two materially different rule sets behind
  one version string, which is precisely what the version exists to prevent -- and nothing would have
  failed, because the string is only ever compared to itself.
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
  after that run: **Site URL on `hjowfnzpomzxazmzywxw` is `https://app.muster.partners` as of
  2026-09-17** (see `docs/EMAIL.md` for why the root rather than `/app`). It was wrong for the
  project's whole life, believed changed on 2026-09-13 and was not -- on 2026-09-15 a real
  magiclink again landed on `https://www.muster.partners/` with live tokens in the fragment.
  The API confirmed it still read `https://www.muster.partners/` on 2026-09-17 at 13:54 UTC,
  which is what two weeks of trusting a note bought.
  **It is no longer a dashboard setting.** `.github/workflows/auth-config.yml` applies it from
  the commit through the Management API and fails the job if the readback disagrees; dispatch it
  with `apply` unchecked for a read-only report of what is live. Two independent runs confirmed
  the new value, and the second one -- a separate process doing its own `GET` -- is why this
  paragraph is allowed to say it changed.
  **What is proven and what is not:** the *value* is set, read back twice. **And the fallback is
  proven**: `muster-auth-smoke` ran against it on 2026-09-23 02:54 UTC, all six read-only steps
  green, and its `allowlist:control` probe -- the one step that exercises Site URL, because it asks
  for a host that must be refused -- fell back to `https://app.muster.partners/` where the
  2026-09-09 run fell back to `www`. A minted recovery link landed on `app.muster.partners/reset`
  with a live recovery session. Three things that run did not cover, and none may be claimed from
  it: the password leg (`rotate_password` was false; set → sign-in last passed 2026-09-09), a real
  **magic** link (the function mints recovery links; same allowlist and fallback, but not followed),
  and delivery (nothing is sent). So write "recovery links land on the app host", not "magic links
  work", until someone has sent a magic link and followed it. Details in `docs/EMAIL.md`. Setting a
  field and delivering a working link are different claims and this file has already conflated them
  once.
  The workflow deliberately leaves `uri_allow_list` alone (`PATCH` is partial). That list is
  correct and was verified byte-identical either side of the change: it carries
  `app.muster.partners/app`, `/reset` and `/**`, the `28footsystems` equivalents, and the
  onboarding landings. **The six auth email templates are applied and verified as of
  2026-09-17**, by `.github/workflows/auth-config.yml` with `templates: apply` -- it PATCHes all
  six subjects and bodies through the Management API, re-reads, and compares each body's sha256
  against the repo file plus each subject exactly, failing the job on any disagreement. Run it
  with `templates: report` for a read-only listing of what is live. They had sat in the repo
  since 2026-09-08 while production served stock: `mailer_templates_custom_contents` reported all
  six false, with bodies of 124 to 270 characters against roughly 4,700 in the files. Nothing
  checked, so nobody knew. **`supabase/auth-email-templates/` is the source of truth and the
  dashboard is a cache of it** -- an apply overwrites anything edited there, deliberately.
  **The seven security-notification emails are a separate family and all seven are switched off**
  (`mailer_notifications_*_enabled` all `false`, read live 2026-09-17). Their templates are still
  GoTrue stock at roughly 190 characters, and that is fine while they are off: writing templates for
  mail that never sends is the same error as activating a rule its engine cannot emit. Check the
  switch before the template -- `templates: report` prints both.
  **One of the seven is a product decision, not a formatting one.**
  `mailer_notifications_password_changed_enabled` is `false`, so changing a password sends the
  account holder nothing. For most products that is a preference; for a vendor selling security
  assurance it is a control a buyer may reasonably expect, and its absence is the kind of thing an
  attacker uses after a credential stuffing win. Turning it on is an outward-facing change that
  starts mailing real users, so it is the owner's call -- and it must ship WITH its template, or the
  first one a customer receives is unbranded stock from a security company.
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
- **A scan rule stays inactive until the engine that emits it is deployed, and `active = false`
  now blocks findings as well as controls.** Not tidiness: an
  active rule the engine never evaluates has no findings by construction, and `sync_controls()`
  scores a reference with no open findings as **met** -- so the register reports a check that was
  never run as passed.
  Until migration `20260917061404` the flag only governed half of that. `rule_control_refs()`
  reads `active`, so the control register was genuinely protected -- but `muster.engine_ingest`
  inserted every finding the engine sent, and `findings.rule_id` is a foreign key to
  `scan_rules(rule_id)`, which an inactive row satisfies perfectly well. The engine has no idea
  which rules are active; it emits everything it evaluates. So the first deploy carrying
  `SEC-014`/`SEC-015`/`EMAIL-008` would have put them straight into every tenant's register,
  scoring against posture, with `autotriage()` opening a risk for `SEC-014` at medium -- while
  `scan_rules.active`, the one place you would look to confirm they had not shipped, still said
  false. Ingest now drops findings whose rule is inactive and reports the count as
  `skipped_inactive` in the scan summary, so a rule the engine is ahead of is visible rather than
  silent. Deactivating a rule therefore also retires its open findings, which is reversible:
  reactivate, rescan, and they reopen against the same fingerprint. Evidence is never gated, only
  findings, so activating later does not lose the artefacts already collected. `SEC-014`, `SEC-015`
  and `EMAIL-008` were held inactive by migration `20260916210100` for exactly this reason and
  **activated by `20260917111614`** once engine `http-native-1.4.0` was observed in production;
  `docs/SCAN-RULES.md` carries the confirmations. Same rule as feature-flag `enforcement`: never
  declare a thing enabled before the code reading it exists. Two things that hold for the next
  rule held this way: a version gate in a migration header is a **floor, not an equality** --
  `20260916210100` named `1.2.0`, which was superseded twice and never deployed, so waiting for
  that literal string would have waited forever. And `skipped_inactive` on a real scan is the
  proof the deploy landed, because it means the engine emitted a held finding and ingest refused
  it; the version string alone is only ever compared to itself.
  **`EMAIL-009` followed the same path on 2026-09-17** (`20260917150811` adds it inactive,
  `20260917161039` activates it after engine `http-native-1.5.0` was observed), and it adds a third
  way to prove the gate. `skipped_inactive` could not be the proof here: the rule correctly emitted
  nothing on the sites scanned, so the counter stayed 0 whether or not the code ran. **Its evidence
  row was the proof** -- `dns_spf_chain` is written whenever the walk executes, pass or fail. When a
  rule's silence is a legitimate result, look for an artefact the engine writes unconditionally,
  not for a counter that only moves when the rule fires.
- **"The engine could not read it" is never reported as "the site is down".** `AVAIL-001` says
  *Site unreachable or returning an error* and tells the reader *Visitors cannot load the site*,
  with remediation pointing at DNS, hosting and TLS. On a site that is actually serving pages,
  every clause of that is false, and it is the worst thing this product can do: a confident claim
  about a page the engine never read. It has now happened twice on real prospect scans, six hours
  apart, through two different doors. `AVAIL-003` (migration `20260917071020`) took the first --
  a homepage answering **401, 403 or 429**, which means the server answered and declined us,
  usually a WAF or bot filter. `AVAIL-004` (`20260917174318`, activated by `20260918053307`, engine `http-native-1.6.0`) takes
  the second -- a response that **arrives and fails HTTP parsing**, which `hpsd.k12.pa.us` did
  with `invalid HTTP header parsed` while serving 200 to a lenient client and to this engine's own
  plain-HTTP probe *inside the same scan*, so the report called the site unreachable and described
  its redirects in the same breath.
  Three things generalise. **Both keep `critical` severity** -- weights are critical 25, high 10,
  medium 4, low 1, from 100, green at 85, so filing an unreadable scan as low scores it 99 and
  renders it GREEN, which is absence-of-findings-as-a-pass, the thing migration 062 exists to
  prevent. What changed is the claim, not the weight, and each finding says outright that the scan
  is an unassessed target rather than a clean one. **The classifier only ever errs toward
  `AVAIL-001`**: `responseRejectedByClient` in `supabase/functions/muster-scan/availability.ts`
  matches a tight list of parse-phase errors and anything unrecognised stays an outage, because
  hiding a real outage is worse than the defect being fixed. That list is only sound because hyper
  raises those errors *after* response bytes arrive, while DNS, connect and TLS failures produce
  different messages -- so a match is evidence a server answered, not a guess; a marker naming a
  connect or TLS phase would break the premise, and a test asserts none does.
  **The activation is also the first time this project's CI actually deployed anything.** Every
  earlier run took the skip path; the `deploy-functions` run on #120 ran its token-proving read and
  spent 37 seconds in `supabase functions deploy`, and scan 63 came back on `http-native-1.6.0` with
  `skipped_inactive: 1` -- the engine emitting a held rule and ingest refusing it, which is the only
  one of those two numbers that proves anything. Scan 63 is also the cleanest illustration of why
  posture is not the product: with the false `AVAIL-001` resolved and `AVAIL-004` still held,
  `hpsd.k12.pa.us` scored **78 amber**, its best number of the day, on a scan that read no markup,
  headers or cookies at all. Activation put it back to 53 red. Same number the bug produced, and now
  it is true.
  And **one test owns the `ENGINE_VERSION` equality pin** -- the newest rule's, today
  `tests/scan/login.test.ts` (it was `availability.test.ts` until AUTH-* took `1.7.0`). `tests/scan/avail-refused.test.ts` was pinning the exact value
  too, so `1.6.0` broke a test about `AVAIL-003`; it now asserts a floor plus its own changelog
  line. If every rule's test pinned the value, one bump would edit all of them and the pressure
  would be to loosen the check rather than move it.
- **The SITREP is a document, and it is judged as one.** `muster.generate_sitrep`
  (latest definition wins; migrations are append-only, so find it by scanning rather
  than by filename -- `tests/sitrep/report-contract.test.ts` does exactly that).
  Four defects were found on 2026-09-18 by reading the report as a borough manager
  would rather than as a function that returns a row, and all four are the same
  family as the rest of this file.
  **It stated a count it did not render.** The finding loop carried `limit 12` from
  migration `013`, so SITREP 55 said "14 open findings: ... 3 informational" and
  rendered 12 with one informational; `GOV-003` and `GOV-004` were absent and nothing
  said so. Nothing could catch it, because the count and the list came from different
  queries and were never compared. The cap is now `c_max_findings` at 50 and the
  report says "Showing N of M"; when the cap binds, a claim names what it is not
  showing. Trimming is fine. Trimming silently is the defect.
  **Its header collapsed once the file travelled.** Organization / Target / Scan were
  three lines joined by single newlines, which every CommonMark renderer folds into
  one paragraph. Nothing in the product exposed it -- `admin.html` wraps `content_md`
  in a `<pre>` and `sitrep.html` never reads `content_md` at all -- so it only bit
  when the `.md` left the building, which is the only thing a `.md` is for. When a
  format is only rendered by your own `<pre>`, you are not testing the format.
  **The markdown and the viewer were different documents.** `sitrep.html` renders four
  sections; the markdown rendered three, omitting Top Findings. This file justifies
  the console's verbatim `<pre>` on the grounds that it "cannot disagree with what the
  tenant reads at /sitrep" -- it did, and in the worse direction: the console reader
  saw less. Both render findings now. **If you add a section to one, add it to both.**
  **And it never stated its own scope.** `docs/SCAN-RULES.md` has always been careful
  that a framework mapping is a citation and not a test, and that the engine has no
  browser and no authenticated crawl -- while the one document a customer actually
  reads said none of it. `## What This Scan Did Not Check` now ships in every report,
  including the line that a clean result is evidence these checks passed on a date and
  not a statement that the site is secure. For a product whose whole case is not
  overclaiming, having the scope boundary anywhere except the deliverable was the
  largest gap in it.
  **The jurisdiction section renders as of 2026-09-23** (migration `20260923015214`, `muster_082`).
  `muster.q_sitrep_jurisdiction` had run on every report since `046` and nothing displayed it. It
  could not be printed as-is: its `status` says `clear` for "no open finding on a mapped rule",
  and six of the YMCA's thirteen laws (CAN-SPAM, TCPA, C2PA, ISO 42001, the OECD principles, PA
  Act 35) map to **no rule at all**, so "CAN-SPAM: clear" would have been a pass on something
  the engine cannot look at. Each law now carries an `assessment` -- `open_findings`,
  `no_open_findings`, or `not_assessed` (no mapped rule, **or** an unread scan) -- decided once
  by `muster.sitrep_jurisdiction_assess` and stored in `sections.jurisdiction`. Both the
  markdown (`muster.sitrep_jurisdiction_md`) and `sitrep.html` read that field and never derive
  a bucket from `status`; `tests/sitrep/jurisdiction.test.ts` runs the viewer's real renderer
  against the negative cases. Every law is shown with its "applies when" condition and the
  payload's own disclaimer leads the section, because a list of statutes under a client's name
  reads as a determination that they apply. **Never render the word "clear" or "compliant"
  here**, and never add a law to the "no open findings" bucket that has no mapped rule.
  `sitrep.html` also gained the scope note ("What This Scan Did Not Check") in the same change;
  it had been in the markdown since `077` and missing from the viewer, which is the rule above
  broken in the other direction. Rendering it exposed two catalogue defects, repaired by
  `20260923044416` (`muster_083`): all 83 AI-governance rows carried `applies_when` as a raw tag
  list ("Covers: highrisk, companion, text, media"), now one plain sentence each saying the law
  applies **only if** the organization uses AI in that way; and BPINA's reference URL ended in a
  stray period. The four tags are defined nowhere in the repo, so their meaning was read off the
  laws carrying them and the mapping is in that migration's header. **`text` means general AI
  use**, confirmed by the owner on 2026-09-23 -- which is why it also tags algorithmic-pricing
  laws, and why it is rendered as broad public-facing AI use rather than "generates text". The
  migration header still calls this an inference; it predates the confirmation and cannot be
  edited, because the file must match what the ledger recorded. A new catalogue row must be written as a sentence -- the migration
  asserts no `Covers:` value survives, but nothing stops one being inserted later.
- **A tenant's own LLM is resolved from the website being narrated, never from the API key.**
  `muster.org_llm_config` (migrations `069`/`070`, wired by `071`) holds one endpoint, model and
  Vault-stored key per organization, and `muster-agent` uses it for `ai_narrative` and the agent
  loop. **Embeddings are excluded on purpose** -- three tables pin `vector(1536)`, so a tenant model
  with other dimensions breaks retrieval and one with the same dimensions silently poisons it; they
  stay on `MUSTER_OPENROUTER_API_KEY`, which is now that key's only remaining use.
  **There is no fallback.** An org with no row gets no LLM and stays on the deterministic generator;
  `runAgentLoop` cannot reach `openRouterKey()`, and `tests/agent/llm.test.ts` asserts the one call
  site left is `embedText`. The reason the lookup is keyed on `website_id` rather than the caller's
  org: `muster_engine_agent_call` only refuses a cross-org narrative when the key *is* org-scoped, so
  a platform key (`organization_id` null) may narrate any tenant's site -- keying off the key would
  have found no config there, and falling back to MUSTER's account would have sent that tenant's
  findings to our provider through the one feature built to stop it, with nothing failing.
  `muster_engine_llm_config_for_website()` does the mapping in SQL so the edge function never names
  an org. Three things that look like polish and are not: the SSRF guard is re-checked at call time
  in `llm.ts` as well as by the `CHECK` constraint, because a guard only on the write path is at the
  wrong end; `reasoning: {enabled:false}` is an OpenRouter extension and OpenAI returns 400 on
  unknown top-level parameters, so sending it to a tenant's own OpenAI account would have failed
  every call and been reported to them as a bad key; and everything written to `last_error` goes
  through `redactSecret()`, because `muster_llm_config` returns `last_error` to a browser. Full
  table of who may call what is in `docs/BACKEND.md`.
  **The workspace sets one as of 2026-09-17.** `Live.renderLlmPanel()` in `app.html` renders it in
  the same view that already holds team, API keys and alert preferences, because this is tenant
  self-service rather than a platform control. Three things about it are deliberate. It reads
  `muster_llm_config` **on demand rather than from the workspace payload** -- one row, read rarely,
  and putting a tenant's provider metadata into every workspace load for every member buys nothing.
  It shows the form only to an executive or a super admin, matching
  `muster_set_llm_config`'s own gate, so a viewer sees the state instead of a form that would raise
  `42501`. And **"not configured" is rendered as a working state, not a fault** -- it means nothing
  from that workspace reaches a language model, which is the honest description and the safe
  default. The key is write-only from the browser: only `key_hint`, the last four characters, ever
  comes back.
- **Edge functions deploy from CI, not from a paste.** `.github/workflows/deploy-functions.yml`
  runs `supabase functions deploy` on merge to main for anything under `supabase/functions/`. It
  skips, rather than failing, until the **`MUSTER_SUPABASE_ACCESS_TOKEN`** repository secret is
  set -- prefixed, because this account's secrets span several brands. The guard accepts the
  unprefixed `SUPABASE_ACCESS_TOKEN` too and names which one it used, so a rename can no longer
  produce a silent green skip. **It deploys now.** The run on #120 (2026-09-18) was the first that
  did, and #121 and #122 each shipped `muster-scan` through it on 2026-09-23 -- runs 35806182345
  and 35806705653, each proving the token by a read before writing. What follows is the history of
  why it did not for three weeks, kept because the failure mode is silent. **On 2026-09-17 neither
  name was visible to this repository**,
  proven by dispatch rather than inferred: a probe printing only whether each candidate was
  non-empty came back empty for both secret forms and both variable forms. A secret defined at the
  organization level without this repo in its access list, scoped to an environment, or added on
  the Dependabot or Codespaces tab arrives as an empty string with no error, which is
  indistinguishable from never having been created. It must be on the **Actions** tab of **this**
  repository. **And it is not a Supabase secret.** This stack has two stores called "secrets" on
  opposite sides of the deploy: `supabase secrets set` writes env into the *deployed edge function
  runtime*, GitHub Actions secrets are env for the *CI job*. The token is consumed by the job,
  before any function exists to read it, so a copy in Supabase cannot reach it -- which is what the
  2026-09-17 investigation turned out to be, after the name had already been corrected. A Supabase
  access token also does not belong there on its own merits: it is a management-plane credential
  that can deploy and modify the project, and storing it as a function secret hands it to all
  twelve deployed functions, none of which need it. The original defect was narrower and worth remembering: the file read
  `SUPABASE_ACCESS_TOKEN` while the secret carried the prefix, so the guard took the skip path on
  all four runs, each reported success, and three rules sat inactive for three weeks behind a green
  checkmark. Two things now stop a repeat: the skip writes a `::warning::` and a job summary saying **nothing was
  deployed**, so it is as visible as a failure; and a configured token is **proven by a read**
  (`supabase projects list`, asserting `config.toml`'s `project_id` is among them) before anything
  is written, so a wrong-account or expired token fails with nothing half-deployed. Dispatch it
  with `verify_only` to check the credential and deploy nothing.
  **Editing this workflow is never a documentation-only change**: the file is in its own `paths`
  filter, so merging any edit to it deploys every function. Check what is currently undeployed
  first -- a function whose source has sat on main unreleased will ship the moment that merge
  lands. Before this, every function in the project was deployed by pasting its source through a chat
  tool, which is fine at 7 KB and stops being fine at `muster-scan`'s **67 KB across four files** (it
  was 38 KB across three when this was written, which is its own argument): the
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
  Do not repeat "Stripe is outstanding" from an older note. **GoTrue SMTP is not outstanding
  either** -- that claim was stale and was disproved on 2026-09-17 by reading the live auth
  config: custom SMTP is configured and sends as `noreply@mail.muster.partners`. It mattered,
  because it changes what an undelivered auth email means: on the built-in sender a missing
  email is an unremarkable rate limit, on configured SMTP it is a real delivery fault worth
  chasing. What IS outstanding: the six auth email templates and the rate limit on the new
  project, and `customer.subscription.deleted`, which nothing consumes.
