# MUSTER scan rules

Every defect code the engine can raise, by audit area. **47 rules, all active**, all
`check_type = http_native` — including the `EMAIL-*` family, which resolves DNS over HTTPS rather
than fetching a page. `check_type` has no `dns` value; the column records how the engine reaches
the network, and every reach is still an HTTPS request.

Source of truth is `muster.scan_rules` on `hjowfnzpomzxazmzywxw`, not this file. Regenerate with:

```sql
select rule_id, category, default_severity, title, framework_refs, plain_english
from muster.scan_rules order by category, rule_id;
```

A finding is reported as `F<id>` (its row in `muster.findings`), and carries the `rule_id` below
plus the evidence ids (`E<id>`) the engine captured for it.

## Sitewide or per page

Not in the catalog, because it is a property of the engine rather than of the rule row: it is decided
by which step of `supabase/functions/muster-scan/index.ts` raises the code.

| Scope | Raised by | Codes |
|---|---|---|
| **Site** — one verdict per domain | the `http://host/` probe; the origin files; domain DNS | `SEC-001`, `GOV-001`, `GOV-002`, `GOV-004`, `SEC-012`, `EMAIL-001`–`007` |
| **Page** — one verdict per page | the fetched response, its headers, its HTML | everything else |

Twelve site-scoped, twenty-six page-scoped.

This matters more than it looks. `website_scan_settings.max_pages` defaults to **1**, so today every
page-scoped rule reports on the homepage only. Raise it and page-scoped codes begin reporting per
page while site-scoped ones stay at one finding each. A code classified wrongly will either duplicate
across a crawl or silently under-report it.

`tools/code-book/` renders this whole catalog, scope column included, as a client-ready PDF.

`tools/local-scan/` runs this same rule set from a terminal against any URL, with no database and
no key — `npm run scan:local -- https://example.com`. It is an adapter over
`supabase/functions/muster-scan/index.ts`, not a second copy of the rules, so the codes below are
the codes it raises. It writes nothing and produces no SITREP; see
[`tools/local-scan/README.md`](../tools/local-scan/README.md).

---

## Security — 15 rules

Eight more rules (`EMAIL-001`..`EMAIL-008`) also carry `category = security`; they are listed under
[Email authentication](#email-authentication--8-rules) below, so the `security` category totals 23.

| Code | Sev | Title | Maps to |
|---|---|---|---|
| `SEC-001` | high | HTTP does not redirect to HTTPS | PCI DSS 4.2.1, NIST PR.DS-2 |
| `SEC-002` | medium | Missing Strict-Transport-Security header | NIST PR.DS-2 |
| `SEC-003` | low | Weak HSTS max-age | NIST PR.DS-2 |
| `SEC-004` | medium | Missing Content-Security-Policy | SOC 2 CC6.6, NIST PR.PT-3 |
| `SEC-005` | medium | Clickjacking protection missing | NIST PR.PT-3 |
| `SEC-006` | low | Missing X-Content-Type-Options | NIST PR.PT-3 |
| `SEC-007` | low | Missing Referrer-Policy | NIST PR.DS-5 |
| `SEC-008` | low | Missing Permissions-Policy | NIST PR.PT-3 |
| `SEC-009` | low | Server software version disclosed | NIST PR.IP-1 |
| `SEC-010` | high | Mixed content on an HTTPS page | NIST PR.DS-2 |
| `SEC-011` | medium | Cookie set without protective flags | SOC 2 CC6.1, NIST PR.DS-1 |
| `SEC-012` | low | No security.txt disclosure policy | NIST RS.CO-1, ISO 27001 A.5.5 |
| `SEC-013` | **critical** | Final page served over HTTP | PCI DSS 4.2.1, NIST PR.DS-2 |
| `SEC-014` | medium | Third-party scripts load without Subresource Integrity | OWASP A03:2025, SOC 2 CC9.2, NIST GV.SC-04, 800-53 SR-3/SI-7 |
| `SEC-015` | low | No CAA record restricts who may issue certificates | RFC 8659, OWASP A02:2025, NIST PR.DS-02, 800-53 SC-17 |

`SEC-015` reads DNS, not HTTP, despite living in this family rather than the email one: a CAA record
governs certificate issuance for the web host, so it is walked from the scanned host upward the way
a certificate authority walks it, not from the `www.`-stripped mail domain.

## Email authentication — 8 rules

Category `security`. These are the only rules that read DNS rather than HTTP: the engine resolves
TXT and MX over DNS-over-HTTPS (Google primary, Cloudflare fallback) and judges the answers. A
resolver failure reports **nothing** — absence of an answer is never treated as absence of a record,
because that would manufacture a high-severity finding out of an outage.

The domain judged is the target host with a leading `www.` stripped. DMARC is looked up walking up
from the host toward the organizational domain, stopping before a public suffix, because a subdomain
inherits its parent's policy.

| Code | Sev | Title | Maps to |
|---|---|---|---|
| `EMAIL-001` | high | No SPF record | RFC 7208, NIST PR.DS-2 |
| `EMAIL-002` | high | SPF does not restrict senders (`+all` or `?all`) | RFC 7208, NIST PR.DS-2 |
| `EMAIL-003` | high | Multiple SPF records | RFC 7208 §4.5, NIST PR.DS-2 |
| `EMAIL-004` | high | No DMARC record | RFC 7489, NIST PR.DS-2 |
| `EMAIL-005` | medium | DMARC is not enforcing (`p=none`, or no `p=`) | RFC 7489, NIST PR.DS-2 |
| `EMAIL-006` | low | DMARC has no reporting address (no `rua=`) | RFC 7489, NIST DE.CM-1 |
| `EMAIL-007` | high | Multiple DMARC records | RFC 7489 §6.6.3, NIST PR.DS-2 |
| `EMAIL-008` | low | No MTA-STS policy | RFC 8461, NIST PR.DS-02, 800-53 SC-8 |

`EMAIL-003` and `EMAIL-007` are high, not medium, and that is deliberate. Both RFCs say a name with
more than one record is a permanent error, so receivers apply none of them. The exposure is
identical to publishing nothing at all, which is `EMAIL-001` and `EMAIL-004`, both high. Severity
tracks what an attacker can do, not how close the operator came to getting it right.

Both are also checked **before** any policy is read from the records. Reading the first record
returned would mean judging a domain on whichever one the resolver happened to hand back first, and
if that one looked strict the scan would report a domain as protected while every receiver ignores
its policy. Telling a client they are covered when they are not is the one failure this family
cannot afford.

`~all` (softfail) is **not** flagged — it is the common, recommended setting, and reporting it would
be crying wolf on a majority of correctly configured domains.

**DKIM is deliberately not checked.** A DKIM record lives at `<selector>._domainkey.<domain>` and
the selector is chosen by whatever sends the mail. Selectors cannot be enumerated from outside, so
"no DKIM" would be a guess, and probing common selectors would report false defects against
correctly configured domains.

**`EMAIL-008` is silent on a domain with no MX record**, and that silence is a result, not a gap.
MTA-STS tells a *sending* server how to reach yours over TLS; a domain that accepts no mail has
nothing for it to govern, so demanding a policy would be inventing a defect. The engine records the
`dns_mx` and `_mta-sts` lookups as evidence either way, because in a report a rule that passed and a
rule that never ran look identical, and only the evidence rows tell them apart.

## Availability — 3 rules

| Code | Sev | Title | Maps to |
|---|---|---|---|
| `AVAIL-001` | **critical** | Site unreachable or returning an error | SOC 2 A1.2, NIST DE.CM-1 |
| `AVAIL-002` | medium | Slow first response | NIST PR.DS-4 |
| `AVAIL-003` | **critical** | Site could not be assessed: the scanner was refused | SOC 2 A1.2, NIST DE.CM-01, 800-53 SI-4 |

## Accessibility — 7 rules

| Code | Sev | Title | WCAG |
|---|---|---|---|
| `A11Y-001` | medium | Page language not declared | 3.1.1 |
| `A11Y-002` | medium | Page title missing or empty | 2.4.2 |
| `A11Y-003` | medium | Images missing alternative text | 1.1.1 |
| `A11Y-004` | medium | Pinch zoom disabled | 1.4.4 |
| `A11Y-005` | low | No top-level heading | 2.4.6 |
| `A11Y-006` | medium | Form fields without an accessible label | 1.3.1, 4.1.2 |
| `A11Y-007` | medium | Links with no discernible text | 2.4.4, 4.1.2 |

## Privacy — 3 rules

| Code | Sev | Title | Maps to |
|---|---|---|---|
| `PRIV-001` | medium | No privacy policy link found | GDPR Art. 13, CCPA 1798.130, CalOPPA |
| `PRIV-002` | low | Third-party trackers loaded before consent could be verified | GDPR Art. 6 & 7, ePrivacy, CCPA opt-out |
| `PRIV-003` | medium | Form submits to an insecure or external endpoint | GDPR Art. 32, NIST PR.DS-2 |

## Governance — 5 rules

| Code | Sev | Title | Theme |
|---|---|---|---|
| `GOV-001` | low | robots.txt missing | Crawl governance |
| `GOV-002` | low | XML sitemap not found | Crawl governance |
| `GOV-003` | info | Meta description missing | AIO readiness |
| `GOV-004` | info | AI crawler directives | AIO readiness |
| `GOV-005` | info | Canonical link missing | AIO readiness |

## AI governance — 5 rules

Category `ai_governance`. These are the only rules keyed to **state statute** rather than a
framework, which is why their `rule_id`s are slugs rather than a numbered family: the citation is
the law, and a numbered code would imply a catalog position the statutes do not have. Adding the
first of them is what broke the control register on 2026-09-16 -- a 30-character key against a
`varchar(16)` column -- which is why `muster.frameworks` is a table now.

| Code | Sev | Title | Maps to |
|---|---|---|---|
| `ai-admt-policy-silent` | high | Automated decision-making used without policy disclosure | Colorado SB 26-189 |
| `ai-chatbot-present-undisclosed` | medium | Conversational AI present without disclosure | Colorado HB 26-1263 |
| `ai-vendor-undisclosed` | medium | Third-party AI vendor undisclosed | — |
| `ai-generated-content-undisclosed` | low | AI-generated content shown without disclosure | California SB 942 |
| `ai-crawler-directives-missing` | info | No AI-crawler policy in robots.txt / llms.txt | — |

**These are disclosure checks, not eligibility rulings.** MUSTER reports that a site appears to use
automated decision-making or a chatbot and publishes no disclosure. Whether a given operator is in
scope of a given statute is a question for the client's counsel, and the finding text says so.

## Third party — 1 rule

| Code | Sev | Title | Maps to |
|---|---|---|---|
| `TP-001` | info | External script inventory | SOC 2 CC9.2, NIST ID.SC-2 |

---

## How the product groups these

The workspace does not show the seven flat categories. It reshapes them into three views.

**Accessibility view** — eight pillars. Seven map one-to-one onto `A11Y-001`..`A11Y-007`; the
eighth is *Browser engine (keyboard, contrast, ARIA)*, which scores **0/10 and is not checked**.
It sits behind the `browser_wcag_engine` feature flag, which is kill-switched. Say so when a client
asks what the accessibility score covers: it is HTTP-native only. Contrast ratios, focus order,
keyboard traps and live ARIA state are **not** assessed today.

**AI readiness (AIO) view** — four pillars over the governance and third-party rules:

| Pillar | Driven by |
|---|---|
| 1. Crawl governance | `GOV-001`, `GOV-002` |
| 2. Entity clarity | `GOV-003`, `GOV-005`, `A11Y-002` |
| 3. AI crawler policy | `GOV-004` |
| 4. Third-party script surface | `TP-001` |

**Risk register** — security, availability and privacy findings promoted to risks.

## Severity distribution

| Severity | Count | Codes |
|---|---|---|
| critical | 3 | `AVAIL-001`, `AVAIL-003`, `SEC-013` |
| high | 8 | `ai-admt-policy-silent`, `EMAIL-001`–`004`, `EMAIL-007`, `SEC-001`, `SEC-010` |
| medium | 17 | `A11Y-001`–`004`, `A11Y-006`, `A11Y-007`, `ai-chatbot-present-undisclosed`, `ai-vendor-undisclosed`, `AVAIL-002`, `EMAIL-005`, `PRIV-001`, `PRIV-003`, `SEC-002`, `SEC-004`, `SEC-005`, `SEC-011`, `SEC-014` |
| low | 14 | `A11Y-005`, `ai-generated-content-undisclosed`, `EMAIL-006`, `EMAIL-008`, `GOV-001`, `GOV-002`, `PRIV-002`, `SEC-003`, `SEC-006`–`009`, `SEC-012`, `SEC-015` |
| info | 5 | `ai-crawler-directives-missing`, `GOV-003`, `GOV-004`, `GOV-005`, `TP-001` |

Only `critical` and `high` open an alert (`muster.notification_outbox` accepts `risk_opened` at
those two severities only — see [`EMAIL-INVENTORY.md`](EMAIL-INVENTORY.md)).

## Framework mapping

`scan_rules.framework_refs` is what every finding, SITREP and control-register row cites.
`muster.controls` is a pure projection of it (`muster.sync_controls`), so a mapping added here
appears in the register on the next scan without any other change.

| Framework | Rules | What it covers here |
|---|---|---|
| NIST SP 800-53 Rev. 5 | 30 | `SC-8`, `SC-17`, `SC-18`, `SC-23`, `CM-6`, `CM-7`, `AC-4`, `SI-4`, `SI-7`, `SI-8`, `PT-4/5`, `SR-3` |
| NIST CSF 2.0 | 28 | `PR.DS-01/02`, `PR.PS-01`, `PR.IR-04`, `DE.CM-01`, `GV.SC-04`, `ID.RA-08` |
| NIST CSF 1.1 | 28 | kept for buyers mid-transition; every value is a withdrawn identifier |
| RFC / other (`CUSTOM`) | 18 | the standard itself where no framework cites it: RFC 7208, 7489, 8461, 8659 |
| SOC 2 (AICPA TSC) | 17 | `CC2.3`, `CC6.1`, `CC6.6`, `CC6.7`, `CC9.2`, `A1.2`, `P1.1`, `P2.1` |
| OWASP Top 10:2025 | 16 | `A02:2025` misconfiguration, `A03:2025` supply chain, `A07:2025` auth |
| OWASP Secure Headers | 9 | one per response header rule |
| WCAG 2.1 | 7 | one per `A11Y-*` rule, A and AA success criteria only |
| GDPR | 3 | Art. 6, 7, 13, 32 |
| PCI DSS | 2 | 4.2.1 |
| ISO 27001 | 1 | A.5.5 |
| US state AI statutes | 3 | Colorado SB 26-189 and HB 26-1263, California SB 942 |

### AVAIL-003: refused is not unreachable

A homepage that answers **401, 403 or 429** raises `AVAIL-003`, not `AVAIL-001`. The server is
running and declined the request -- commonly a WAF, CDN bot filter or rate limiter rejecting
`MUSTER-Scanner/1.0`. A 404 homepage is genuinely broken and a 5xx is genuinely an outage, so both
stay on `AVAIL-001`.

This exists because a real prospect scan reported a live site as a critical outage and told the
reader, in plain English, that "Visitors cannot load the site," with remediation pointing at DNS,
hosting and TLS. Every clause was false. It is the mirror of issue #93: a confident claim about a
page the engine never read.

`AVAIL-003` keeps **critical** severity, which looks wrong and is not. Severity drives posture
(critical 25, high 10, medium 4, low 1, off 100; green at 85), so filing a refused scan as low
would score an unreadable site 99 and render it **green** -- a clean bill of health for a site
MUSTER could not read. What changed is the claim, not the weight: the finding now says the scan
produced no assessment. One request cannot distinguish bot protection from a 403 served to
everyone, so the remediation answers both readings.

DNS-derived rules are unaffected by a refusal and still run: SPF, DMARC, CAA and MTA-STS do not
depend on the web server.

### Held for the engine deploy, activated 2026-09-17

`SEC-014` (Subresource Integrity), `SEC-015` (CAA) and `EMAIL-008` (MTA-STS) are **active** as of
migration `20260917111614`. They were added by #103 and deliberately held inactive by
`20260916210100` for three weeks until the engine that evaluates them was actually deployed. The
hold is over; the reason for it is not, and the next rule added ahead of its engine gets the same
treatment.

**Why a rule waits for its engine.** `rule_control_refs()` projects every *active* rule into the
control register, and `sync_controls()` scores a reference `met` when a scanned website has no open
findings against it. A rule the engine never evaluates has no findings by construction, so an
active-but-unevaluated rule renders as a **met control** -- a report saying a site was checked for
SRI and passed, when it was never checked. That is a fabricated assurance, which is the worst thing
a compliance product can emit.

**The hold is enforced at ingest, not only in the control register.** Migration `20260917061404`
makes `muster.engine_ingest` drop findings whose rule is inactive. Before it, the flag governed
`rule_control_refs()` only, and the engine -- which does not know which rules are active -- would
have written findings into live registers the moment it deployed. A scan reports how many it
dropped as `skipped_inactive` in its summary, so an engine running ahead of its schema is visible
rather than silent. That counter is what proved the deploy: scan 51 reported
`skipped_inactive = 1`, meaning the engine emitted a held finding and ingest refused it -- stronger
evidence that the code path runs end to end than a version string, which is only ever compared to
itself.

**What the hold outlasted, and why "or later" mattered.** `20260916210100`'s header names engine
`http-native-1.2.0`. `1.2.0` was **never deployed**: it was the version at #103, superseded in the
repo by `1.3.0` (#93, #94) and then `1.4.0` (#106, #107) before any of them reached production,
which sat on `1.1.1`. Production went `1.1.1` -> `1.3.0` (2026-09-17 06:56) -> `1.4.0` (07:17).
Waiting for the literal `1.2.0` would have been waiting for a version that will never be served.
Read a version gate as a floor, never as an equality.

**The deploy was blocked silently for three weeks.** `.github/workflows/deploy-functions.yml`
skips rather than fails when `SUPABASE_ACCESS_TOKEN` is unset, and that secret was unset -- its one
run to date, on #103's merge, skipped both deploy steps and reported success. Nothing announced
that the rules were parked. A gate that skips on a missing secret needs someone watching the
result, or it is a silent no-op.

**Verified live, not assumed.** Scan 52 against `muster.partners` on engine `http-native-1.4.0`
returned `skipped_inactive: 0` and produced evidence for all three:

| Rule | Evidence kind | Outcome |
|---|---|---|
| `SEC-014` | `html_excerpt` (external script hosts) | **medium finding**, `cdn.jsdelivr.net` loads `@supabase/supabase-js` with no `integrity` |
| `SEC-015` | `dns_caa` | ran, genuine pass -- four `issue` records present |
| `EMAIL-008` | `dns_txt` on `_mta-sts`, plus `dns_mx` | ran, correctly suppressed -- the domain publishes no MX, so there is no inbound mail to police |

That last row is the distinction to hold onto when reading a quiet rule: **no finding and no
evaluation look identical in a report and are not the same thing.** The evidence rows are what
separate them, which is why a DNS lookup is recorded even when it returns nothing.

The finding on `SEC-014` is against MUSTER's own marketing site, which is the correct outcome.
Its remediation is not a one-liner: `index.html` pins a floating major
(`@supabase/supabase-js@2`), and a hash cannot be taken of a file that is meant to change. Pinning
an exact version comes first, and `SEC-014`'s remediation text says so.

`SEC-014` is the rule worth understanding. It **excludes** tag managers, analytics, chat widgets
and payment scripts, because those files are meant to change and pinning a hash breaks them on the
vendor's next deploy. "Add SRI to Google Tag Manager" is advice that takes a site down. The finding
says how many scripts it excluded and points at CSP and vendor review for those, rather than
pretending they are fine or inventing a defect nobody can fix. That exclusion is
pinned by `tests/scan/hardening.test.ts`, which treats it as the most important case in the file.

Three things about this that matter when a client asks:

**A mapping is not a test.** Citing `A02:2025` says the finding belongs to that category. It does
not say MUSTER tests the category. The engine is HTTP-native with no browser and no authenticated
crawl, so injection, broken access control and authentication are out of reach by construction and
always will be under this architecture. The register states the same limit on every row.

**The CSF 2.0 pass was a correction, not an addition.** Every `NIST_CSF` value was a CSF 1.1
identifier, and 2.0 withdrew all of them. `TP-001` cited `ID.SC-2`, which no longer exists anywhere
in IDENTIFY: supply chain became `GV.SC` under the new GOVERN function. A prospect's GRC team
working in 2.0 could not have reconciled it.

**None of this is a SOC 2 opinion.** A SOC 2 report is issued by a licensed CPA firm after an
examination. What MUSTER produces is continuous, timestamped, independently collected evidence a
client hands to that firm, plus readiness signal between audits. Route the attestation question to
the client's auditor.

**Not mapped, deliberately:** OWASP ASVS. ASVS 5.0 renumbered against 4.0 and the current chapter
identifiers were not verifiable when this pass was made. Guessing control identifiers in a
compliance product is the one unrecoverable mistake, so ASVS waits for someone with the document
open.

Frameworks live in `muster.frameworks` (key, label), which `controls.framework` references by
foreign key. Adding one is an insert there, not a constraint edit. Before 2026-09-16 the set was a
hardcoded `CHECK` plus a `varchar(16)` column, and the AI-governance rules broke the whole register
for an hour by introducing a 30-character key.

## What the engine does not check

Worth being able to say out loud, because a prospect will ask:

- **No browser engine.** Everything is HTTP-native: headers, HTML parsing, and fetches of
  `robots.txt`, the sitemap and `/.well-known/security.txt`. No rendering, no JavaScript execution,
  no computed styles.
- **No authenticated crawl.** Only what an anonymous visitor sees.
- **One page by default.** `website_scan_settings.max_pages` defaults to 1.
- **No DKIM or BIMI check.** SPF and DMARC are covered by the `EMAIL-*` family above; DKIM cannot
  be checked without knowing the selector, and BIMI is not assessed. **MTA-STS is now covered** by
  `EMAIL-008`.
- **No TLS certificate inspection.** Expiry, chain and cipher suite are not assessed, and this is a
  runtime limit rather than an oversight: the edge runtime's `Deno.connectTls()` exposes only the
  negotiated ALPN protocol in `TlsHandshakeInfo`, with no access to the peer certificate. Reading
  expiry from Certificate Transparency logs instead was considered and rejected -- CT shows what was
  *issued*, not what the server is *serving*, so "your certificate expires in five days" could be
  said of a certificate that was replaced a month ago. A wrong expiry warning on a compliance report
  is worse than no expiry warning. It needs either a browser engine or a helper that can complete a
  TLS handshake and read the chain.
