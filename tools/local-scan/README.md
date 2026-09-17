# `tools/local-scan` — run the scan engine from a terminal, with no database

```bash
npm run scan:local -- https://example.com
npm run scan:local -- https://example.com --json /tmp/example.json
```

Behind an HTTPS proxy, add `NODE_USE_ENV_PROXY=1` (Node >= 22.21) or Node's `fetch`
bypasses the proxy and every check reports the site unreachable.

## Why this exists alongside the real engine

There are now three ways to get findings for a URL, and they are not competing:

| | Writes to the database | Needs | Use it for |
|---|---|---|---|
| `muster-scan` edge function | yes — evidence, findings, SITREP, alerts | service-role key, a queued scan for a tenant website | every real client scan |
| admin console → *Run a URL scan* | yes — into the admin sandbox org | super admin session | an ad-hoc URL you do not want in a tenant's register |
| this tool | **no** | Node >= 22.18 and network egress | triage, CI, a machine with no keys, or a site you are not scanning for a client |

This one writes nothing, opens no incident, sends no alert, and produces no SITREP
narrative — that is generated in Postgres and by `muster-agent`. It reports the
findings, the evidence artefacts and the posture score, and exits non-zero if any
finding is `critical` or `high` (the two severities that open an alert in the
product), so CI can gate on it.

## It is an adapter, not a copy

The 38 rules live in exactly one place: `supabase/functions/muster-scan/index.ts`.
`adapt.mjs` reads that file at runtime and removes four things — the Deno runtime
typings import, the Supabase client, the two `muster_engine_*` RPCs at the tail of
`runScan()`, and the `Deno.serve()` handler. Every rule, threshold, evidence key
and the `MUSTER-Scanner/1.0` user agent come through untouched.

Each transform asserts it matched exactly once, and the excised tail is checked for
`add({` before being dropped, so a restructured engine makes this **fail loudly**
rather than quietly scan with different rules.
`tests/scan/local-scan.test.ts` pins all of that, plus an end-to-end scan of a
local HTTP server, and is part of `npm test`.

The one thing genuinely reimplemented is the posture score, in `score.mjs`, copied
from `muster.severity_weight` / `posture_score` / `posture_band` in
`supabase/migrations/20260907223344_muster_012_helper_functions_sql.sql`. **Change
the weights in one place and you must change the other**, or a local scan and a
real scan will report different postures for the same site. One difference is
structural: the database sums every open finding for a website across all of its
scans; this sums one scan's findings. For a first scan they are identical.

## What it still cannot tell you

Everything in [`docs/SCAN-RULES.md`](../../docs/SCAN-RULES.md) under *What the
engine does not check* applies here identically — it is the same engine. No browser
engine, no JavaScript execution, one page, no DKIM, no TLS inspection. A
client-rendered page reports as such and downgrades the confidence of the content
rules; that is the engine being honest, not a defect in this runner.
