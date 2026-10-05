# browser engine changelog

An engine's version moves whenever its rule output changes, because a finding's severity is only comparable
across scans on the same version. This engine versions independently of `http-native-*`.

## browser-1.0.0 (2026-10-05)

First version. Rules, all inactive until activated by a later migration (see `docs/BROWSER-ENGINE.md`):
`A11Y-008`, `A11Y-009`, `A11Y-010`, `TP-002`, `PRIV-006`, `SEC-021`, `SEC-022`, `FORM-001`, `FORM-002`,
`FORM-003`, `FORM-010` and `FORM-011` (the last two only with a stored authorization), plus the process
behaviours `OPS-001` and `OPS-002` and the `REPORT-001` title fix in the report generator.

Playwright 1.56.1 (Chromium), axe-core 4.13.0 pinned. Up to 25 same-origin pages from the sitemap, else the
homepage's links; robots.txt respected; `networkidle`, 30 s per page, two retries on a failed navigation.
One fresh context per scan; no bypass of the page's CSP.

Schema: `scans.engine`, `scans.options`, `scan_authorizations`, evidence kinds `browser_page`, `axe_results`,
`request_list`, `cookie_jar`, `console_log`, `form_inventory`, `csp_probe`, `dns_ns`, `active_test`; flags
`browser_engine`, `browser_active_tests`. Existing http-native functions scoped to their own engine.
