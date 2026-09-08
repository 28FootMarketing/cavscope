# MUSTER scan rules

Every defect code the engine can raise, by audit area. **31 rules, all active**, all
`check_type = http_native`.

Source of truth is `muster.scan_rules` on `hjowfnzpomzxazmzywxw`, not this file. Regenerate with:

```sql
select rule_id, category, default_severity, title, framework_refs, plain_english
from muster.scan_rules order by category, rule_id;
```

A finding is reported as `F<id>` (its row in `muster.findings`), and carries the `rule_id` below
plus the evidence ids (`E<id>`) the engine captured for it.

---

## Security — 13 rules

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

## Availability — 2 rules

| Code | Sev | Title | Maps to |
|---|---|---|---|
| `AVAIL-001` | **critical** | Site unreachable or returning an error | SOC 2 A1.2, NIST DE.CM-1 |
| `AVAIL-002` | medium | Slow first response | NIST PR.DS-4 |

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

## Third party — 1 rule

| Code | Sev | Title | Maps to |
|---|---|---|---|
| `TP-001` | info | External script inventory | SOC 2 CC9.2, NIST ID.SC-2 |

---

## How the product groups these

The workspace does not show six flat categories. It reshapes them into three views.

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
| critical | 2 | `AVAIL-001`, `SEC-013` |
| high | 2 | `SEC-001`, `SEC-010` |
| medium | 10 | `SEC-002`, `SEC-004`, `SEC-005`, `SEC-011`, `AVAIL-002`, `A11Y-001`–`004`, `A11Y-006`, `A11Y-007`, `PRIV-001`, `PRIV-003` |
| low | 9 | `SEC-003`, `SEC-006`–`009`, `SEC-012`, `A11Y-005`, `GOV-001`, `GOV-002`, `PRIV-002` |
| info | 4 | `GOV-003`, `GOV-004`, `GOV-005`, `TP-001` |

Only `critical` and `high` open an alert (`muster.notification_outbox` accepts `risk_opened` at
those two severities only — see [`EMAIL-INVENTORY.md`](EMAIL-INVENTORY.md)).

## What the engine does not check

Worth being able to say out loud, because a prospect will ask:

- **No browser engine.** Everything is HTTP-native: headers, HTML parsing, and fetches of
  `robots.txt`, the sitemap and `/.well-known/security.txt`. No rendering, no JavaScript execution,
  no computed styles.
- **No authenticated crawl.** Only what an anonymous visitor sees.
- **One page by default.** `website_scan_settings.max_pages` defaults to 1.
- **No email-authentication rules.** Nothing checks SPF, DKIM or DMARC, which is the most common
  way a business gets impersonated. There is no `EMAIL-*` family.
- **No TLS certificate inspection.** Expiry, chain and cipher suite are not assessed.
