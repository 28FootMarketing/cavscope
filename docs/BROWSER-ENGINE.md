# Browser engine (`browser-1.0.0`)

A second scan engine beside `http-native`. It loads a site's pages in headless Chromium, runs their
JavaScript, and checks what a visitor's browser actually ends up with. It exists because the HTTP engine
cannot see anything a page builds after load: rendered accessibility, the requests a page really makes,
cookies set by script, forms assembled by script.

**Status as of 2026-10-05: built, tested, schema live, rules inactive, no worker deployed.** Nothing here
changes a customer's report until all of: a worker is running, the `browser_engine` flag is switched on for
an organization, a `browser-1.0.0` scan is observed, and the rules are activated by a later migration.

## Where it runs

Not in an edge function: Chromium cannot run there. `workers/browser-scan/` is a Node 22 worker for a host
that can (the `Dockerfile` uses the Playwright base image; the Playwright version in the image tag and in
`package.json` must match, currently 1.56.1). It polls `public.cavscope_engine_claim_browser`, runs the scan,
and sends the result through the same `public.cavscope_engine_ingest` the HTTP engine uses.

```
SUPABASE_URL=https://hjowfnzpomzxazmzywxw.supabase.co
SUPABASE_SERVICE_ROLE_KEY=...      # service role: the engine RPCs are revoked from everyone else
POLL_SECONDS=20                    # optional
BROWSER_PROXY=...                  # optional, only for a host whose route out is an egress proxy
```

`node workers/browser-scan/cli.mjs <url>` runs the engine with no database and writes nothing.

## How a scan is requested

`public.cavscope_request_browser_scan(website_id, cache_bust, active_tests)`: member who can write the org,
flags `browser_engine` and `manual_scans`. It queues a `scans` row with `engine = 'browser'` and never kicks
anything over HTTP; the worker finds it. Browser and HTTP scans are deduplicated separately, so one never
blocks the other. `engine_claim` and `do_request_scan` were changed to ignore browser scans, and
`engine_ingest` to reconcile only the rule family its scan owns; read the header of
`20261005020553_browser_engine_foundation.sql` for why each had to change.

## What it checks

| Rule | Severity | Check |
|---|---|---|
| `A11Y-008` | per axe impact (critical high, serious medium, moderate low, minor info) | axe-core 4.13.0, tags wcag2a/aa, wcag21a/aa, wcag22aa, best-practice, on every page; one finding per axe rule per site |
| `A11Y-009` | info | axe "incomplete" results, as **needs review**, never pass or fail. Contrast cases over gradients are settled from computed colours (WCAG formula, 4.5:1 text, 3:1 large text and UI) |
| `A11Y-010` | medium / low | title, exactly one h1, valid `html lang`, images without `alt` |
| `TP-002` | info | every request, grouped by host outside the site's registrable domain |
| `PRIV-006` | medium | cookies and tracker hosts **observed before interaction** |
| `SEC-021` | medium | CSP refusals in the console; first-party requests that fail (and also fail over plain HTTP) |
| `SEC-022` | info | a harmless inline script is injected on one page: refused or executed |
| `FORM-001` | high | form with no usable action, or a non-HTTPS destination |
| `FORM-002` | medium | text-message consent readiness, nine items, per form |
| `FORM-003` | info | parent/guardian notice near a personal-data form on a youth-facing page |
| `FORM-010` | medium | active: seven-case endpoint matrix |
| `FORM-011` | high | active: live end-to-end submit |
| `OPS-001` | | wait for a deploy marker before scanning (`options.wait_for`, CLI `--wait-for=`) |
| `OPS-002` | | "DNS is managed at <provider>" appended to DNS-type fixes in the report |

Every rule yields a result, so a clean scan lists what passed (`summary.browser_checks`, rendered as
**Browser Engine Results** in the report). A pass means these checks found nothing on this date. Nothing here
says a site is compliant.

Two design points worth knowing:

* **axe-core is injected through the DevTools protocol, not by bypassing the page's CSP.** The page keeps its
  own policy for everything it does; the evidence records that. The SEC-022 probe goes through the DOM
  instead, because that is the path a policy governs, and its own console message is excluded from SEC-021.
* **A form with `action="#"` is observed, not guessed.** The collector fills it with test values and submits
  it with every network request aborted in the browser; only the destination is recorded. Nothing is sent. A
  script-driven form therefore reads as "submits over HTTPS to X", and a dead form reads as dead.

## Active tests (FORM-010, FORM-011)

They send data, so they are off by default and gated twice. **In SQL**: flag `browser_active_tests`, an
unrevoked, unexpired `scan_authorizations` row granted by an **executive of the owning organization** (not a
super admin) on a site with `verified_at` set, whose domain matches. **In the worker**, again, before any
request: a numeric authorization id on the scan, a verified site, an HTTPS endpoint, and an endpoint host that
is on the site's domain or named in the authorization (`cavscope_set_scan_authorization_hosts`). A request
without authorization is not an error: the scan runs without them and the report says so. At most 3 scans per
domain per UTC day run them. Every value sent is a marker: name `CAVSCOPE TEST (delete me)`, email
`cavscope-test@example.com`, phone `5555550100`. Delivery is never claimed: the report says "delivery not
verified" and lists the strings to delete. Whether a bot submission was stored cannot be seen from outside
without a verification hook, and no such hook exists yet.

## Not checked (and the report says so)

Screen reader testing, keyboard navigation (focus order, traps, focus visibility), zoom and reflow at
200-400%, Core Web Vitals, broken links across the whole site, SPF and DKIM discovery. Pages beyond the first
25, anything behind a login, and anything in a shadow root or frame the contrast probe cannot reach.

## Activating it

1. Deploy the worker; set its two env vars.
2. In the console: `browser_engine` kill switch off, override on for one organization.
3. Request a scan; wait for `engine_version = 'browser-1.0.0'` on a completed scan.
4. A later migration sets `active = true` on the rules. Not before: ingest drops findings for inactive rules
   and counts them in `skipped_inactive`, which is the proof the engine ran ahead of its schema.
5. `sync_controls` treats a browser rule as assessed only where a browser scan has completed, so activating
   the rules cannot score an unrun engine as met.

## Known limits, stated plainly

* **`TP-002` does not retire `TP-001`.** The brief asks that it supersede it. That needs a "superseded"
  finding status the schema does not have; TP-001 is info and carries no score weight, so nothing is
  misscored, but both can be open at once.
* **OPS-002 appears only after a browser scan.** The NS records are read by the browser engine; teaching the
  HTTP engine to record them would move its version for a report convenience.
* **Evidence is cut to 8,192 characters by ingest**, with the sha-256 computed over the whole captured text.
  Full axe JSON for a large page is therefore truncated in storage.
* **Layout-dependent axe results from a degraded load can be wrong.** A page that lost some of its own files
  yields low-confidence findings that say so.
* **Verified on real bytes, not from a production worker.** See `workers/browser-scan/CHANGELOG.md`.
