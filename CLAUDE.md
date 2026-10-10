# CavScope — standing rules for this repo

## Brand: CavScope is the product and the system of record. MUSTER is retired.

This repo builds **CavScope, Web Assurance by 28 Foot Systems**, served at
`https://cavscope.28footsystems.com/`. `MUSTER` was the product's previous name. **As of
2026-09-30 the owner's direction is that MUSTER is no longer part of this product in any
form, customer-facing or internal.** The target is zero. Do not add a new `muster_*` RPC,
`muster-*` function, `muster.partners` link or MUSTER string, and do not describe MUSTER as
a "deliberate internal codename" -- that was the earlier position and it has been reversed.

What still carries the name, and why it has not been renamed yet, is an inventory, not a
policy: the callable backend surface (`public.muster_*` RPCs, `muster-*` edge functions and
the cron jobs that call them), the `x-muster-api-key` header and `mk_` key prefix, and
migration filenames, which are history and never renamed. Each is staged for retirement in
`docs/RENAME-PLAN.md`; renaming one breaks callers unless it follows that order. Customer-visible
leftovers are defects to fix, not identifiers to preserve.

**The MUSTER-era hosts redirect, as of 2026-09-30.** `muster.partners`, `www.`, `app.`,
`onboarding.`, `sitrep.` and the `*.muster.28footsystems.com` originals answer every request
with a 308 to the same page on `cavscope.28footsystems.com` (`legacyTarget()` in
`middleware.js`, pinned by `tests/routing/middleware.test.ts`). No page renders under the old
name, and every link already delivered still works: a browser carries an auth link's
`#fragment` across the redirect, so a magic link minted for `app.muster.partners/app` still
signs its holder in, on the CavScope origin.

**The database schema is `cavscope`**, not `muster`, on `hjowfnzpomzxazmzywxw` (read from the
live catalog 2026-09-30). What still
carries the old name is the callable surface -- 112 `public.muster_*` RPCs and 18 `muster-*`
edge functions. As of 2026-10-01 the RPC rename is applied (109 `cavscope_*` functions with
`muster_*` aliases) and every page, edge function, tool and test in this repo calls the
`cavscope_*` names, so **new code calls `cavscope_*`**; the aliases stay until stage 5 of the plan.
The edge-function **directories** are `supabase/functions/cavscope-*` as of stage 3 half A; the
old `muster-*` slugs stay deployed, frozen at their last version, until stage 5. Pages, cron jobs and
database call sites use the `cavscope-*` slugs as of stage 3 half B (2026-10-01); the Stripe, GHL,
Resend and Telegram webhooks still deliver to the old slugs until stage 4, so a change to a webhook
function does not reach its live traffic until that webhook is repointed.
Where the rest of this file names an RPC as `muster_foo`, call `cavscope_foo`. Where the rest of this file says `muster.<table>` or `muster.<function>` for
the database, read `cavscope.`. The staged plan to retire the remaining names is in
`docs/RENAME-PLAN.md`.

**Reading the rest of this file:** many rules below were written under the MUSTER name and
are left as originally written, because they are a historical and technical record --
migration headers, verified live-config values (a Site URL, an SMTP sender name, an
`ENGINE_VERSION` string) and war stories about what actually shipped and when. Where you
see `MUSTER` used as the product's customer-facing name in prose below, read it as
`CavScope` -- the two files documenting the actual current split are `docs/BRAND-CUTOVER.md`
(what changed, what didn't, why) and this section. Where `MUSTER` appears as part of an
identifier (`muster_bar`, `muster-baz`, a migration filename), it still names the live thing
until `docs/RENAME-PLAN.md` retires it; `muster.foo` means `cavscope.foo`; and a
`muster.partners` / `app.muster.partners` host in a rule below now redirects to the same path
on `cavscope.28footsystems.com`, which is where that rule applies.

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

## Pick from what CavScope already knows: dropdowns, not text boxes

A standing rule from the owner, 2026-09-30, applying to every page the same way tooltips do.
**When the answer to a field already exists in CavScope's data, the field is a dropdown (or a
checklist), fed from that data, never a text box.** One thing is then always spelled one way,
which is what keeps reports, exports and filters consistent. It was adopted after the two beta
signups on file turned out to have typed "Consulting" and "Business Operations Consulting" for
the same industry.

What that means today, each pinned by `tests/ui/pick-lists.test.ts`:
- **Industry** is `cavscope.industries`, read through `public.cavscope_industries()` (anon and
  authenticated, migration `20260930184023`). `app.html`, `onboarding.html` and `beta.html` each
  bundle a copy so the dropdown renders before the read returns; the test fails if a copy drifts
  from the migration. A value saved before the list existed stays selected and is marked
  "(as entered before)", never silently replaced. To add an industry: insert a row, then update
  the three bundled copies.
- **Country** comes from `muster_countries()` and **region** from `muster_regions()`;
  **timezone** from the browser's own `Intl.supportedValuesOf('timeZone')`.
- **A live workspace's website** is picked from the websites registered to it (`globalSiteSelect`,
  `Live.selectWebsite`). Until 2026-09-30 the workspace always opened `websites[0]`, so an
  organization's second site was unreachable anywhere in it.
- **SITREP recipients** are a checklist of the team, with one optional field for people who have
  no login; the **LLM provider** is a preset list that fills in the endpoint.

Free text stays where the answer is genuinely new: a name, a URL being registered for the first
time, a reason, a model id only the provider can spell. When you add a field, ask first whether
CavScope already holds its possible answers; if it does, it is a dropdown. A new catalog is a
table plus a `cavscope_*` read function -- never a new `muster_*` one.

## Instructions and long lists collapse, one open at a time

The same standing rule, second half. **Anywhere someone reads a sequence of items -- a report's
sections, each finding's fix, a list of steps -- the items are collapsible, and opening one
closes the others in its group**, so nobody scrolls past one item to reach the next.

The engine is `initAccordions()` plus `accordionSections()` and `setAllAccordions()`, copied
into `app.html`, `admin.html`, `sitrep.html` and `sitrep-sample.html` the way the tooltip engine
is, and started beside `initTooltips()`. It is native `<details>`/`<summary>`, so keyboard,
screen reader and find-in-page support come with the element. A `<details class="acc">` with a
`data-acc-group` joins a group; `accordionSections(root, selector, group)` converts a rendered
report's heading-led blocks without their templates changing, keeps the first open, and adds
"Open all" / "Close all". Each finding's remediation is a "How to fix" `<details class="acc
acc-fix">` in the report tables, the AI-readiness findings and the accessibility defects.
**Printing opens every collapsed item and restores them afterwards** -- a printed SITREP or PDF
must never be missing a section a reader happened to have closed. Pinned by
`tests/ui/accordions.test.ts`; checked in Chromium on 2026-09-30, including Enter on a focused
summary, open-all, and print.

**A new page, or a new list of steps or fixes, gets the same treatment.** Onboarding is
already one step at a time and is the exception by design. Legal and policy pages
(`privacy.html`) stay fully expanded: a disclosure someone has to open to read is a disclosure
that was not made.

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
between `/* cavscope:tokens:start */` and `/* cavscope:tokens:end */`, written there by
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

**As of 2026-10-01 there are 36 flags: 26 wired, 10 enforced nowhere.** Read that from
`muster.feature_flags`, not from here -- this paragraph said "four are wired" until the count
was checked, by which point it was 25, and the registry had grown from 22 keys to 35, then 36.
The ten were triaged 2026-10-01 and none is a hidden hole: the console already marks each
"read by nothing" with its switches disabled. Four are Partner or Enterprise entitlements with
nothing behind them (`client_management_enabled` does not exist as a capability,
`commercial_use_enabled` is a licence term, `custom_branding_enabled` is redundant with
`white_label_enabled`, `enterprise_enabled` is per-contract), `partner_dashboard_enabled` gates a
view that is visible to everyone and was left ungated while no Partner organization could hold
client data, `super_admin_console` is in the inventory only, and three are kill-switched unbuilt
features (`browser_wcag_engine`, `pdf_export`, `public_status_badge`) plus `telegram_alerts`, which
is off by default and unbuilt. Registry prose says CavScope as of that date; lowercase
identifiers inside it (`muster_admin_run_url`, `muster-agent`) stay until they are renamed. The
`enforcement` column is the answer; a number written in prose is a snapshot that rots.

The four wired first, by migration `20260916022923`, are still the ones whose behaviour is worth
knowing: `scheduled_scans` (the due-scan CTE in `muster.engine_claim`; `next_run_at` is not
bumped for a gated website, so switching it back on resumes rather than having skipped windows),
`email_alerts` (`muster_engine_claim_alerts` — the gate is on the **claim**, so off holds
already-queued alerts as `pending` rather than dropping them), `support_impersonation` and
`admin_url_scanner`.

Each of the ten unwired rows carries a `wiring_note` saying why and what would wire it.
`commercial_use_enabled` can never be wired — it is a licence term, not a code path, and must
not be presented as a control. **`client_management_enabled` was the one that was a commercial problem
rather than a deferred feature, and it is wired as of 2026-10-02** (migrations `20261002031035`,
`20261002031051`, `20261002031639`; the read for the console is `20261002031759`): 27 flags wired, 9 not.
The Partner tier was sold with client organizations and nothing created one. Now
`public.cavscope_create_client_org` does, through `cavscope.do_create_client_org`, and it refuses unless
all of these hold: the caller is executive (or super admin) on the Partner, the organization has a
**`partner_client_allowance`** (null = not a Partner), the flag is on, the Partner is not itself a
client (no chains), the name is 2 to 120 characters and unique among its clients, the industry is on the
list, and there is room under the allowance. **Past the allowance it refuses; it does not give extras
away**, because billing for the $39/$49 add-on organizations is not built. The client inherits the
Partner's plan, website limit and commercial stage, and the creator becomes its executive, so RLS and the
tenant switcher work unchanged. **Partner status is an explicit allowance a super admin sets** (Client
Access in `admin.html`, `cavscope_admin_set_partner_allowance`), never inferred: the Stripe grant records
plan and stage but not the tier, so a Partner is indistinguishable from an ordinary Pro buyer in the
database, and guessing would give the allowance to the wrong people. **Wiring the Stripe tier through to
the allowance is the open follow-up**; until then a Partner who buys needs a super admin to switch their
allowance on, and `index.html` says so. In a live workspace the "+ Tenant" button is shown only to a
Partner whose organization can create clients; it used to open the self-serve onboarding and make an
independent trial organization. `tests/ui/client-orgs.test.ts` pins the guards; the SQL was exercised in
a rolled-back transaction against the live database.

**`pdf_export` is wired as of 2026-10-02 and ships dark** (migrations `20261002032527`, `20261002032531`):
28 flags wired, 8 not. `cavscope-sitrep-pdf` renders a SITREP's own markdown (the text the console shows
verbatim and the `.md` export carries, so the three cannot disagree) with pdf-lib, whose standard fonts
supply the glyph widths, because there is no headless browser here. It runs as the caller, never as the
service role, stores nothing, and asks `public.cavscope_pdf_export_allowed(sitrep_id)` before it reads the
report: a member of the report's organization or a super admin, flag on for that organization, and the
kill switch off. **The kill switch is ON**, so nobody can use it until an owner turns it off in the
console and grants an organization the flag. `sitrep.html` shows "Download PDF" only when that check says
yes and fails closed. Text a standard font cannot draw (CJK, emoji) becomes `?` rather than stopping the
report. `tests/pdf/` pins the renderer and the wiring; the access check was exercised in a rolled-back
transaction. It is the report as a document, not the viewer's page, so it has no accordions or colours.

Nav gating in `app.html` (`Live.navFlagMap` / `applyFlagsToNav`) **fails open**: a key
missing from the workspace payload leaves the nav item visible. These flags gate
visibility, not authority — the RPC behind every view enforces RLS whatever the sidebar
shows — so a partial load must not silently strip half a tenant's workspace.

## Other notes

- **The browser engine exists, is tested, and is dark, as of 2026-10-05.** `workers/browser-scan/` loads
  pages in headless Chromium (Playwright, axe-core pinned) and reports rendered accessibility, third-party
  requests, cookies before interaction, CSP behaviour and forms. It is a second engine, `browser-1.0.0`,
  beside `http-native-*`, not a replacement, and it cannot run in an edge function: it runs as a Vercel function,
  `api/browser-scan.mjs` (`docs/BROWSER-ENGINE.md`), the owner's host; **do not propose or ask about any other host**.
  Migrations `20261005020553`, `20261005021804`, `20261005022456` and `20261005024226` are applied. The function holds
  no service-role key: it holds the anon key and a Vault secret that the `cavscope_worker_*` RPCs check, and
  **`CAVSCOPE_BROWSER_WORKER_SECRET` must be set on the Vercel project by the owner** (the deploy connection cannot
  create production env vars). `vercel.json` now exists, for `functions` only; the routing rule below still
  holds, and `tests/browser/api.test.ts` fails if it gains a routing key. **All twelve rules are inactive and both flags (`browser_engine`,
  `browser_active_tests`) are dark.** Things that were not obvious and are pinned by
  `tests/migrations/browser-engine.test.ts`: the HTTP engine's `engine_ingest` resolved every open
  `http_native` finding a scan did not re-observe, so a browser scan would have resolved all of a site's
  findings (reconcile is now per engine); it also wrote `detected_*_code` unconditionally, which a browser
  scan would have nulled; `sync_controls` scored a reference with no findings as met, which would have read
  an engine that never ran as a pass (a browser rule now counts only where a browser scan completed). The
  pre-existing `browser_wcag_engine` flag (kill switch on, read by nothing) was the placeholder for this; it
  was left alone and `browser_engine` is the flag that is actually read. **The active tests (FORM-010,
  FORM-011) send data and are gated in SQL and again in the worker**; never aim them at a site without a
  stored authorization, and never at a live site to "see if it works". Fixtures and the Playwright run live in
  `tests/browser/` (`npm run test:browser`; the unit half is in `npm test`). **The Supabase MCP connection
  hangs on `DELETE` and `DROP FUNCTION` statements (observed 2026-10-05); write such steps so they do not
  need them, or hand the SQL to the owner.**

- **The site is checked by its own browser engine, and it failed, as of 2026-10-05.** The first production browser scan of
  `cavscope.28footsystems.com` found 5 axe issues and 23 text-contrast failures on a product that sells accessibility
  auditing. Causes, all fixed and pinned by `tests/ui/site-accessibility.test.ts`: `--text-dim` (`#5d708e`) was 2.5 to
  3.9:1 on every dark surface (now `#8798b4`, 4.8:1 or better), red text needs `--rose-text` not `--rose`, the tooltip
  engine kept an EMPTY `role="tooltip"` node on every page (it is `hidden` until it has text, in all ten copies), the
  public pages had no `<main>` landmark, the workspace had three unlabelled dropdowns (axe's only critical), four
  `role="button"` cards that contained real buttons, and white initials at 2.8:1. **After changing any page, run
  `node tools/site-axe/run.mjs`** (serves this repo's pages through the engine, writes nothing). It cannot see
  `/admin`'s or the workspace's signed-in panels, which are template-built and need a session. A new `role="tooltip"`,
  a new page without `<main>`, or a muted-text colour under 4.5:1 on a dark surface will fail the test, not wait for a scan.

- **Support is a tab on the right edge of the workspace and the console, not an email link, as of 2026-10-03.** `tools/support/widget.html` is the one source; `node tools/support/sync.mjs` writes it into `app.html` and `admin.html` between `<!-- support:start -->` and `<!-- support:end -->` (same arrangement as the design tokens, pinned by `tests/support/widget.test.ts`). A signed-in person picks a category from a fixed list, writes a message and, unless they untick it, sends a screenshot of the page, taken in their browser with `html2canvas` (pinned by integrity hash, served from `cdn.jsdelivr.net`, which the CSP already allows) with password fields blanked and the widget left out of its own picture. `cavscope-support-request` (JWT required) files the request through `public.cavscope_submit_support_request` under the caller's JWT (category list, org membership, 10 an hour), then emails the `support@` row of `cavscope.mail_routes` with the screenshot attached, Reply-To the person. **The screenshot is attached and stored nowhere**: it can show anything on a screen, so `cavscope.support_requests` records only `has_screenshot`. If the email fails the request stays on file as `failed` and the person is told it was saved, not delivered. Nothing reads `support_requests` in a browser; there is no inbox view yet, the email is the inbox. Do not put a `mailto:` support link back in either page's navigation.
  **AI triage is wired and ships dark, as of 2026-10-03** (flag `support_ai`, kill switch on, default off; migrations `20261003042946`, `20261003042948`, `20261003043005`): after the original email, a model reads the message, the screenshot and a few account facts (`cavscope_engine_support_context`) and support gets a second email with a summary, what is on screen, a likely cause, a suggested fix and a **draft** reply. Nothing the model writes is sent to the customer; there is no `to: customer` anywhere and `tests/support/ai.test.ts` fails if there is. The customer is told on the panel and in `privacy.html` that an AI may read what they send. It runs after the response (`EdgeRuntime.waitUntil`), skips quietly with no OpenRouter key, and the model slug is a setting (`CAVSCOPE_SUPPORT_AI_MODEL`, default `anthropic/claude-sonnet-4.5`, **not yet exercised live**). The screenshot is still stored nowhere; only the model's written notes (`ai_*`) are. How to work a request, and why fixes are not automatic, is in `docs/SUPPORT.md`.

- **The Findings Glossary is a view in the workspace, read from the rule catalogue, as of 2026-10-03.** `public.cavscope_finding_glossary()` (anon and authenticated, like the industry list; migration `20261003185523`) returns every non-retired rule in `cavscope.scan_rules` -- title, usual severity, plain-English meaning, how to fix, and `checked` (the rule's `active` flag) -- and `app.html`'s Findings Glossary view renders it, grouped by area, one item open at a time, with a search and a severity pick-list. **Nothing in it is typed**, so a rule added to the engine appears with no page edit, and `tests/ui/glossary.test.ts` fails if a rule id is hardcoded into the view. A rule held inactive reads "Not currently checked", never as a check that runs, and the page says a scan with none of these means those checks passed that day and is not a statement that the site is secure. `framework_refs` are deliberately not returned: they are citations, not tests. Building it surfaced three rules that still said "MUSTER" to customers, one of them telling them to allow a `MUSTER-Scanner` user agent the scanner stopped using on 2026-09-30; `20261003185521` corrected them. Rule text is read into every report, so a rule's wording is customer copy. `docs/GLOSSARY.md` remains the glossary of terms, and `docs/SCAN-RULES.md` the engineer-facing table.

- **The public beta signup is closed, as of 2026-10-02, at the owner's instruction.** `/beta` answers a 307 to `/` and `beta.html` is kept, unrouted. The real control is the `public_insert_only` policy on `public.muster_beta_signups`, now `with check (false)` (migration `20261002001225`), because the table was insertable straight through PostgREST regardless of the page. The 2 existing rows are untouched. To reopen: set the policy back to `with check (true)` and restore the `/beta` rewrite in `middleware.js`.

- **`cavscope.28footsystems.com` is the one host, path-routed for everything.** `/` is the landing
  page, `/onboarding`, `/sitrep`, `/sitrep/sample`, `/privacy`, `/signin` and `/reset`
  (both `signin.html`), `/app` and `/admin`. Marketing, sign-in, the workspace and the console
  share one origin, which is what a Supabase session needs: it is stored per-origin, so
  `signin.html` and `app.html` on different hosts would make sign-in appear to succeed and then
  load the workspace signed-out. The MUSTER-era split into `muster.partners` and
  `app.muster.partners` existed only for that reason, and those hosts now redirect here (see the
  Brand section).
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
  a cancelled customer stops pricing in once `customer.subscription.deleted` is handled (see the
  Stripe notes below; until the endpoint is subscribed to that event, one still prices in). Two nav sections (Workspaces, Domain Monitor) render
  an explicit "not instrumented" panel naming what would have to exist first, because the schema
  cannot answer them; if you build one of those, replace the stub, don't fill it with a plausible
  table. **AI Readiness stopped being a stub on 2026-10-10**: its panel said no assessment existed,
  which had been false since the nine-check AIO audit shipped on 2026-09-23. It is now backed by
  `public.cavscope_admin_aio_overview()`, which judges every site's latest completed HTTP scan the way
  the workspace's AIO view does (a check passes only if its rule could have fired). **Reports stopped being one of them on 2026-09-17**, backed by
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
  **Beyond the console payload it makes six side reads** (`SIDE_READS`): the flag registry,
  impersonation status and log, `muster_admin_platform_extras()` (platform agents and the
  jurisdiction review queue -- built in migration 068 for this page and never wired until now),
  `muster_admin_overview()`, kept **only** for its `incidents` list, because triage needs incident
  ids and the console payload reduces them to counts, and `muster_admin_site_jurisdictions()`
  (every site's detected location, any override on it, and what the resolver makes of both). Each settles on its own: one failing blanks its
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
  Subscription **cancellation is handled as of 2026-10-01**: `gateSubscriptionDeleted` in `core.ts`
  routes `customer.subscription.deleted` to `public.cavscope_engine_cancel_subscription`
  (migration `20261001011757`, applied and exercised in a rolled-back transaction: downgrade to
  trial, idempotent redelivery, a plan moved by hand left alone and logged, an unclaimed grant
  voided, a re-purchase clearing the cancellation). It works because grants now record the claiming
  organization (`organization_id`, set in `do_onboard`). It takes effect only when the function is
  deployed (merge to main) **and** the Stripe endpoint is subscribed to the event, which is a
  dashboard step nothing here can verify -- until then a cancelled customer keeps their plan. **Delivery to `cavscope-stripe-webhook` was observed 2026-10-02** (a resent checkout event, POST 400 at 00:03 UTC: signature accepted, payload refused for missing `tier`/`stage`). **The cancellation event was never observed arriving**: a `stripe trigger customer.subscription.deleted` ran in the Stripe *sandbox*, which does not reach an endpoint registered in live mode. The owner accepted it as passed on 2026-10-02 on the strength of the offline tests and has not seen it delivered; the first real cancellation is the first live proof. It
  deliberately acts on `deleted`, not on a scheduled-cancellation notice, so a customer keeps what
  they paid for. Nothing is deleted on downgrade; websites over the trial limit are not disabled.
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
  `supabase/functions/cavscope-scan/index.ts` — it reads that file and strips the Supabase client, the two
  `muster_engine_*` RPCs and `Deno.serve()`, asserting each cut — so there is still exactly one copy of
  the rule set. The one thing duplicated is the posture weights, copied from
  `20260907223344_muster_012_helper_functions_sql.sql` into `tools/local-scan/score.mjs`; change one and
  you must change the other. `tests/scan/local-scan.test.ts` pins the adapter and scans a local server
  end to end.
- **`/audit/html` is a fifth way to get findings: pasted HTML, for a site CavScope does not scan,
  as of 2026-09-30.** `html-audit.html` posts a page's HTML to the `cavscope-html-audit` edge
  function, which runs the engine's page rules on it and, on request, applies the fixes the
  operator chose and returns the corrected HTML to download. The rules are not copied: they moved
  out of `runScan()` into `muster-scan/page-checks.ts`, which the engine and the audit both import
  (engine output proven identical before and after, so no `ENGINE_VERSION` change). The fix engine
  is `cavscope-html-audit/fixes.ts`, under `tests/html-audit/`. Three things are deliberate.
  **It never writes words for the site owner**: alt text, titles, labels, descriptions and the
  organization name come from a person or are skipped, and an image nobody answered is left alone
  rather than given an empty alt. Only mechanical fixes (a language from the list, re-enabling
  zoom, http to https, an integrity hash) apply by default. **Every result states its scope**:
  headers, cookies, redirects, DNS and availability cannot be read from pasted HTML, and a clean
  audit says so. **Nothing is stored**: the HTML may be a client's unpublished page, so the
  function has no table, no log line and no activity event; its only database call is the gate.
  Its one outbound request hashes scripts the operator ticked for SRI, and only those the page
  itself names, over https on a public name, no redirects, 5 s, 2 MB, 20 at most.
  **Access is the `html_audit` flag** (migration `20260930202245`), off for every organization:
  super admins always have it, a workspace only by an override in the console's Feature Flags.
  `public.cavscope_html_audit_allowed()` decides, under the caller's JWT, and a kill switch stops
  super admins too. The workspace's "HTML Audit" link fails **closed** on
  `flags.html_audit === true`, unlike `navFlagMap`, because it is an off-by-default capability, not
  a view a partial load should keep.
- **Rule logic that can be pure belongs in a sibling module with tests, not inline in `runScan()`.**
  `supabase/functions/cavscope-scan/html.ts` is that module today: `stripTags`, `stripToBodyText` and
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
  `vercel.json` holds only `functions` config for `api/browser-scan.mjs`; don't add routing to it.
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
  work", until someone has sent a magic link and followed it. **That has now been reported:** the
  owner sent one to a mailbox they read and followed it on 2026-10-01 and says it works. It was
  not observed by this repo's tooling and does not say which address or landing host, so the
  claim is "a magic link can arrive and sign someone in". An address on Resend's suppression
  list still gets a 200 from GoTrue and no email (the QA sentinel's has since 2026-09-09), so a
  suppressed person sees "check your email" and never receives one. Details in `docs/EMAIL.md`. Setting a
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
  **That rule was missed five more times and is now a test (2026-10-01).** Only
  `engine_error_spike` and `control_register_failure` could ever close: `cron_failure` and
  `cron_missed` open at **critical** severity and could not, and `scan_silent_failure` had left 39
  incidents open since 2026-09-17 (35 were scans where the engine emitted findings for rules still
  held inactive and ingest dropped them, per `skipped_inactive`; the check cannot tell that from a
  broken engine, so the incident evidence now carries `engine_version` and `skipped_inactive`).
  `commercial_grant_stuck` and `alert_dead_letter` had the same flaw. All seven sources close when
  their rolling-window check comes back clear, and `tests/scan/watchdog-close-paths.test.ts` fails
  if a source is added that cannot. A grant voided by a cancellation (`cancelled_at`) is excluded
  from "stuck", or a deliberate cancellation would read as a failure after 48 hours.
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
- **The AIO / GEO audit view is wired to the engine, as of 2026-09-23.** Before that, "Run AIO
  Audit" printed a scripted terminal ("llms.txt -> HTTP 404", "Schema.org Organization found",
  "empty `<div id=root>` shell") for **every domain, signed in or not**, the live index was the
  site's security posture relabelled, and the llms.txt and structured-data pillars had no rule
  behind them. Now a live workspace's button calls `muster_request_scan` on its registered website,
  polls to a terminal status, and reports each check; the sample walkthrough labels every scripted
  line `[SAMPLE]`. The pillars are nine checks over nine rules, three of them new (`GOV-006`
  llms.txt, `GOV-007` JSON-LD, `GOV-008` client-rendered homepage; added inactive by
  `20260923042421`, shipped in engine `http-native-1.10.0` when PR #129 finally merged on
  2026-09-28 -- written as `1.8.0`, but `1.8.0` and `1.9.0` were taken while it sat open --
  and activated by `20260928164840`). **A check with no finding is a pass only if its rule could
  have fired**: active per `public.muster_rule_status` (`20260923042540`), a scan on an engine at or
  past the rule's floor, and a homepage the engine actually read. Otherwise it is "not assessed" and
  excluded from the index -- the same absence-of-findings-is-not-a-pass rule as everywhere else.
  Citability is never scored; no provider publishes how it picks citations. Pinned by
  `tests/ui/aio-view.test.ts` and `tests/scan/aio.test.ts`; table in `docs/SCAN-RULES.md`.
- **A SITREP's jurisdiction is the scanned site's state, not the scanning workspace's, as of
  2026-09-28.** `q_sitrep_jurisdiction` read `organizations.region_code` only, so every URL parked
  in the admin sandbox org inherited its one `PA` and got PA Act 35, whatever the site was.
  `supabase/functions/cavscope-scan/legal.ts` now reads a state the site states about **itself**
  (governing-law clause, postal address, then -- weakest -- a full state name in the meta
  description) off the homepage and up to three same-origin legal/about/contact pages, into
  `websites.detected_country_code`/`detected_region_code`, which the query prefers over the org's.
  No match stays null, never a guess. `PRIV-004` (no Terms of Service link) shipped alongside it
  and was activated by `20260928213241`. Two things generalise, both found only by rescanning the
  real sandbox sites after each deploy, and neither catchable by the test suite alone:
  **a looser signal will eventually match something it shouldn't** -- the meta-description tier
  labelled After Today's own site Washington state off "Anthony Washington Sr.", fixed in `1.14.0`
  with a narrow suffix guard that is documented as narrow -- and **a persistence guard can outlive
  the thing it protected**: `engine_ingest` refused to overwrite a detection with null, so the
  corrected engine's null never reached the row and the wrong `WA` survived the scan that disproved
  it. `20260928205820` writes the latest answer unconditionally. The local-scan adapter has no
  database, so a persistence bug is invisible to `tests/scan/`; rescan and read the row.
  **A location-based law list is not the list of laws that apply, and every report says so**
  (`20260928215356`). The section picks laws by one place, where the organization is, while much
  privacy law reaches a business through where its customers live: a Pennsylvania site's list has
  no CCPA and no GDPR, and read cold that absence reads as "these do not apply". That is
  absence-as-a-determination again. `cavscope.jurisdiction_residency_note()` writes one of two
  fixed paragraphs (laws listed / none listed), `q_sitrep_jurisdiction` emits it as
  `residency_note` on **every** return path, including both that list nothing, because an empty
  section is the one most easily read as "nothing applies", and the markdown, `sitrep.html` and
  `app.html` print it verbatim before the law lists. Its CCPA and GDPR examples say "can reach"
  with the condition that makes them reach; never reword either into a determination.
  `SAMPLE_SITREP` carries SQL's exact words and a test compares them.
  **The workspace says the same thing** (`20260928220554`). Its "Laws and Standards" panel
  (`q_compliance_posture`) printed each law's raw status, `clear`, under a disclaimer quoting the
  word; onboarding's preview was headed "What applies to you"; and the workspace export listed
  every law as a control that was "Effective". Status keys are unchanged, but `app.html` now
  renders them only through `LAW_STATUS_LABEL` ("No open findings", "Not assessed", ...), both
  payloads carry `residency_note`, and the preview says "Commonly relevant where you are based".
  **One location, decided once** (`20260929033108`). Until then `q_compliance_posture` read the
  organization's record while the SITREP read the site's own stated state, so on an agency's client
  site the workspace and the report named different places. Both now call
  `cavscope.website_jurisdiction(website_id)`: the site's detected state, else the organization's
  record (never the sandbox org's), else nothing assumed, with the `location_source` sentence the
  panel and the report both print. **Never add a caller that reads `organizations.country_code`
  for a site's laws**; `tests/sitrep/jurisdiction.test.ts` fails if either caller does. The
  migration proved the SITREP byte-identical on every website before it could commit.
  **A super admin can override it per site** (`20260929033647`), in `admin.html`'s Website
  Assurance section: `websites.jurisdiction_override_*`, set and cleared only through
  `muster_admin_set_site_jurisdiction` (super admin, anon revoked, every change an activity event),
  taken by the resolver **before** detection and the organization's record -- for a sandbox site
  too, which is the only way an ad-hoc audit of a site that states nothing gets a law list. Its
  sentence reads "Set by a CavScope administrator on <date>, in place of what the site states", plus
  the admin's reason, **which the tenant reads in their workspace and SITREP**, so write it for them.
  The engine never writes these columns, so a rescan cannot undo an override. Changing a real
  tenant's site confirms first; a sandbox site does not.
- **The Overview's four tiles show a live workspace its own numbers, as of 2026-09-28.** Until then
  they were fixed HTML: every signed-in tenant saw the sample's posture 82, "1 active critical
  risk", control coverage 80% ("4 of 5 mapped"), evidence readiness 75% ("3 approved artifacts")
  and remediation 65% on the first screen of their workspace, and `stampScoreTimestamps()` labelled
  each "As of" the current minute, so the fiction read as fresh. Nothing replaced them and no test
  noticed, because every test read the source rather than running what a tenant runs.
  `renderOverviewKpis()` now fills them from the workspace payload -- posture and band from
  Postgres, control coverage from the latest SITREP's own figures, remediation from the risk
  register -- and **Evidence is a count, not a percentage**, because nothing tracks whether an
  auditor reviewed anything; a readiness figure would be invented. Scan evidence in the library is
  `Captured` / `Not reviewed`, no longer `Approved` by "CavScope engine". Each tile's explainer is
  built from the same data (`liveScoreExplainer()`), and the modal hides the sample's "80 is Good"
  benchmark for it, because CavScope's real bands are green at 85, amber from 60. Demo mode restores
  the sample and stamps it "Sample data". `tests/ui/overview-kpis.test.ts` runs the real renderer
  against a fake DOM built from the tiles' own markup, and fails all nine cases on the old file.
  **That change shipped a regression, fixed the same day:** the Controls and Evidence tiles read
  `latest_sitrep.sections`, and the overview payload's `latest_sitrep` is a stub with no sections,
  so a real tenant read "No report yet" beside a report that existed. The test fed an assumed
  payload shape. Evidence now counts `latest_scan.summary.evidence` (18 on org 3's scan 126),
  not the SITREP's evidence index, which lists only what the report cites (2).
- **A live workspace is checked by rendering it, not by reading it (`tools/live-sweep/`).** On
  2026-09-28 every workspace view was rendered in Chromium in demo mode, as a live tenant fed that
  tenant's real payloads, and in demo again, and the two diffed. What it found, none of it visible
  to a test that reads source: **both workspace reports were broken for every tenant** -- nothing
  fetched `muster_latest_sitrep`, so each said the report "was generated before the report template
  existed" (the section above describing `renderReport()` was true only in demo); the
  **Accessibility "Health Index" was the security posture relabelled**, every rule with no finding
  scored 10/10 whether or not it ran, and the summary described the sample's fictional keyboard
  trap; "Within Tolerance", "Formally Approved" (the appetite table records a save, never an
  approval), the Governance tolerance figures, "Fleet Conformance 86%" and "Deliverables 12" were
  fixed text **nothing ever wrote**; scans were listed as "Effective" control tests; six record
  forms (risk, control, evidence, exception, remediation action, control test) updated page state,
  toasted success and saved nothing; `hidden` did nothing on any element whose class sets
  `display`, which is why the sample client presets stayed on a live AIO screen; and "Show demo"
  left the tenant's real SITREP, laws and team on a screen labelled sample data. Each is fixed:
  accessibility is scored like AIO (pass only if the rule could have fired, browser-only areas
  "not assessed", never a conformance rating), the no-backend forms are hidden and refused in live
  (`DEMO_ONLY_MODALS`), and fixed text a live view replaces goes through `liveCopy()`, which
  restores the sample's own markup in demo. The mechanical rule that found half of these is now a
  test: **every id-bearing element with visible text inside a workspace view must be written by a
  script**, three named headings excepted (`tests/ui/live-sweep.test.ts`, which fails all fifteen
  cases on the old file). **Rerun `tools/live-sweep/` after changing any workspace view.** Its
  fixture is a real tenant's findings and is gitignored; never commit it.
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
  `AVAIL-001`**: `responseRejectedByClient` in `supabase/functions/cavscope-scan/availability.ts`
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
  `tests/scan/legal.test.ts` (it was `aio.test.ts` from `1.10.0`, `login.test.ts` from `1.7.0`, and `availability.test.ts` before that). `tests/scan/avail-refused.test.ts` was pinning the exact value
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
  `20260923044416` (`muster_085` -- renumbered from `083` on 2026-09-23 when two migrations
  applied directly against the live project, with no file here, turned out to have the true claim
  to `083`/`084` by version; see `supabase/migrations/README.md`): all 83 AI-governance rows
  carried `applies_when` as a raw tag
  list ("Covers: highrisk, companion, text, media"), now one plain sentence each saying the law
  applies **only if** the organization uses AI in that way; and BPINA's reference URL ended in a
  stray period. The four tags are defined nowhere in the repo, so their meaning was read off the
  laws carrying them and the mapping is in that migration's header. **`text` means general AI
  use**, confirmed by the owner on 2026-09-23 -- which is why it also tags algorithmic-pricing
  laws, and why it is rendered as broad public-facing AI use rather than "generates text". The
  migration header still calls this an inference; it predates the confirmation and cannot be
  edited, because the file must match what the ledger recorded. A new catalogue row must be written as a sentence -- the migration
  asserts no `Covers:` value survives, but nothing stops one being inserted later.
- **The report is a template emitted by Postgres, and every page renders it.** As of 2026-09-25
  (migration `20260925200050`, `muster_109`) `sections.report` on every SITREP carries the header
  block, the metrics, control coverage (`muster.sitrep_controls`), the section list each report
  shows in order (`profiles.client`, `profiles.board`) and the disclaimer. `app.html`'s Plain
  English (client) and Board & Committee (company) reports are one renderer, `renderReport()`,
  walking a profile's section list; `sitrep.html` reads the same payload; the markdown gained
  `## Controls` in the same migration. **A page decides how a section looks, never which
  sections a report has.** To add a section: emit it from `generate_sitrep`, name it in the
  profile(s) in `sitrep_report_model`, add a `case` to `renderReportSection` in `app.html`, a
  block in `sitrep.html` and a heading in the markdown -- `tests/sitrep/report-template.test.ts`
  fails on any of those left out, and a key the template names that `app.html` cannot draw renders
  as a visible notice rather than nothing. Until this change the two workspace reports were demo
  scaffolds with hardcoded copy ("Q3 Standing Brief") and different headers, a signed-in tenant got
  a findings list under one and raw markdown under the other, and the client report printed as an
  empty page because its print rule named `#plainReportView`, an id that never existed. Demo mode
  renders `SAMPLE_SITREP` (fictional, Northstar Fintech) through the same renderer, and the test
  pins its profiles to SQL's, so a prospect sees the document shape a customer gets. Branding comes
  from `getActiveBrand()` into the report's own header and footer; white-label hides the MUSTER
  line, co-branded says "with MUSTER". The finding status and promote controls in the client
  report's Findings table are workspace actions, marked `.no-print`, and never reach paper.
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
  **A paste deploy still happened on 2026-10-06 and drifted from main for three days.**
  `cavscope-alert-dispatch` version 6 was deployed through the MCP at 16:10 UTC, after the last
  commit, with the support address moved off the shared `MUSTER_SUPPORT_EMAIL` secret (which held a
  `muster.partners` address) onto a `CAVSCOPE_SUPPORT_EMAIL` default; nothing committed it and no
  branch carried it, so the next CI deploy touching functions would have put the MUSTER footer back on
  every alert. Found on 2026-10-09 by comparing `list_edge_functions` timestamps against `git log`
  (an MCP deploy's `entrypoint_path` starts with `/tmp/user_fn_`, a CI deploy's with
  `/home/runner/work/`) and committed the same day. **Check that before trusting any function's
  source: a deployed function whose `updated_at` is later than its directory's last commit is drift
  until proven otherwise.**
- **Mail to `support@` and `security@` reaches a person, as of 2026-09-30.** Resend receives
  it on `mail.cavscope.28footsystems.com` (and the retired `mail.muster.partners`, so old links
  still land) and posts `email.received` to the `cavscope-inbound-mail` edge function, which
  forwards each message to that address's row in `cavscope.mail_routes`, Reply-To the sender, so
  answering from the owner's inbox answers whoever wrote in. Security mail is tagged
  `[CavScope SECURITY]`. Before this nothing read those addresses at all: no Resend webhook
  pointed at this project, and `security.txt` was sending researchers to an address nobody saw.
  Where an address forwards is a row, changed with an `update`, never a deploy; the forward-to
  inboxes are deliberately not in any migration file. The signing secret is Vault's
  `cavscope_resend_inbound_webhook_secret`, read only by the service role, and a missing secret
  fails closed. The Resend account is shared with other brands, so the function answers every
  event not addressed to a CavScope route with 200 and reads nothing about it. A forward is
  never sent to a CavScope mailbox, which is what makes a loop impossible. Pinned by
  `tests/email/inbound-mail.test.ts`; setup and proof in `docs/EMAIL.md`.
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
- **Backend: Supabase project `hjowfnzpomzxazmzywxw`, schema `cavscope`.** CavScope has its own project; `supabase/config.toml` and all five frontend pages point at it, and `supabase/migrations/` is its
  history. Real scan engine, SITREP generation, RLS, and RPCs are live — see `docs/BACKEND.md`.
- **The old shared 28FS project `mgtmqucaldkaxvxglguw` runs no part of the product.** That was
  believed true from 2026-09-08 and was not: a `muster-scan-due-15min` cron job (jobid 150) was
  active there from about 2026-09-15, scanning three sites daily into the old `muster` schema,
  including one that was never a CavScope client. Found by reading `cron.job` on 2026-09-30 and
  **paused** (`cron.alter_job(150, active := false)`, 113 jobs before and after, active 96 to 95).
  It sent no email and had no live API key. Before claiming this project is inert again, read
  `cron.job` for anything naming `muster`, not this paragraph. What is still there: the
  `muster` schema (45 tables, 58 functions), the 70 `public.muster_*` shims, and 8 deployed edge
  functions, all dormant. Removing them needs the Supabase CLI — the MCP has no delete for edge
  functions — and is tracked in `supabase/migrations/CAVSCOPE-PROJECT-LEDGER.md`.
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
  project, and subscribing the Stripe endpoint to `customer.subscription.deleted` (handled in code
  since 2026-10-01; the dashboard step is the owner's).
