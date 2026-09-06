# WORKFLOW-COVERAGE — MUSTER

MUSTER is a website-assurance/compliance-monitoring SaaS: it scans a tenant's website on a cadence, turns findings into evidence-backed SITREPs and a tracked risk register, and advises on jurisdiction-specific obligations. It is not a booking, inventory, or physical-service product — several of the generic discovery categories in the assignment (scheduling, inventory/resources, service preparation, aftercare) are marked NOT_APPLICABLE below with evidence, not silently dropped.

Each row: ID · Plane · Responsibility · Trigger · Current status · Evidence · Desired end state · Blocking dependency.

## PLATFORM / OWNER PLANE

| ID | Responsibility | Trigger | Current status | Evidence | Desired autonomy | Blocked by |
|---|---|---|---|---|---|---|
| P-01 | Prospect acquisition (marketing page, pricing display) | visitor loads `index.html` | VERIFIED_WORKING | `index.html` pricing section, `muster_public_pricing()` RPC | fully automated (already is) | — |
| P-02 | Trial tenant provisioning | visitor completes signup on `app.html` | VERIFIED_WORKING (code) / PRESENT_UNVERIFIED (Auth dashboard redirect config) | FIND-009 | fully automated | verify Auth Site URL/Redirect URLs live (BLOCKED_ACCESS from this sandbox) |
| P-03 | Trial → paid conversion / billing collection | human marks GHL deal "Closed Won" | HUMAN_DEPENDENT (by design, phase 1) | FIND-010, `muster-ghl-webhook/index.ts` | reduce human step to "approve," not "execute," or full self-serve for base tier | **B-1** (GHL vs. Stripe decision) |
| P-04 | Reconciling GHL pipeline state against MUSTER org `plan` | none — no reconciliation exists | MISSING_CONFIRMED | no matching function found in `muster.*` routines | detect and alert on drift (a Closed-Won deal with no matching org, or an org on `trial` past a threshold) | **B-1** |
| P-05 | Entitlement/plan enforcement (website_limit, feature flags) | RPC call time | VERIFIED_WORKING | `muster.plans`, `muster_admin_set_plan`, feature-flag resolution order documented in BACKEND.md | already automated | — |
| P-06 | Platform subscription metering / usage-based billing | n/a — flat plans only | NOT_APPLICABLE_WITH_EVIDENCE | no usage-metered pricing dimension found in `commercial_pricing` (flat monthly + per-additional-org for Partner) | n/a unless pricing model changes | — |
| P-07 | Payment recovery / dunning (failed card, expired subscription) | n/a today | MISSING_CONFIRMED | no `muster.*` payment/invoice table found; billing lives entirely in GHL/Stripe, outside this schema | needs a reconciliation job once B-1 is resolved and an actual payment record exists to reconcile against | **B-1** |
| P-08 | Tenant support / ticketing | n/a | MISSING_CONFIRMED | no support/ticket table in `muster` schema (contrast: `isupport` exists as a *separate* product in the same Supabase project, not wired to MUSTER) | decide: reuse `isupport`, or is support handled entirely outside MUSTER (e.g. email/GHL)? | decision needed, not detailed further this pass |
| P-09 | Release process | manual (this session's own git+PR workflow) | HUMAN_DEPENDENT (appropriately — releases should stay human-approved) | this session's own commit/PR/merge history | keep human-approved; the gap is CI validation before merge, not approval itself | FIND-011 |
| P-10 | Security operations (advisories, RLS review) | manual, per-session | PARTIAL | this session ran `get_advisors` manually; no scheduled/automatic run found | scheduled advisor check with alert on new WARN/ERROR touching `muster` | not detailed this pass |
| P-11 | Abuse controls (rate limiting, API key abuse) | none found | MISSING_CONFIRMED | no rate-limit table/function found scoped to `muster_agent`/`muster-scan`; contrast: `open_endpoint_rate_limit` table exists for *other* products in the same project | needs a decision on whether MUSTER's public/anon RPCs (`muster_countries` etc.) and the `muster-agent` gateway need rate limiting | not detailed this pass |
| P-12 | Cost management / spend visibility | none found scoped to muster | MISSING_CONFIRMED | no cost-tracking table/view for muster's own scan/agent/GHL-call volume | scan volume and GHL API call counts are cheap to log; worth a lightweight view | not detailed this pass |
| P-13 | Backups / restore drills | unknown from this audit | BLOCKED_ACCESS | Supabase-managed backups exist at the project level (platform default) but no muster-specific restore drill evidence was found or sought via MCP | needs an explicit drill, out of scope for MCP-only audit | requires Supabase dashboard/CLI access this session doesn't have |
| P-14 | Incident recovery / self-healing routing | none found | MISSING_CONFIRMED | no incident/ticket table, no wiring to a self-healing agent found in `muster` schema | out of scope to build without an incident system decision first | not detailed this pass |
| P-15 | Knowledge maintenance (jurisdiction law corpus freshness) | manual | HUMAN_DEPENDENT | `muster.jurisdictions` "review queue" concept exists (`muster_admin_overview` returns `jurisdiction_review_queue` for jurisdictions unreviewed >180 days) — VERIFIED_WORKING as a *surfacing* mechanism, but the actual review/update is still a human editing law rows | surfacing is already automated; the edit itself is properly a human/legal-research task, not automatable — correctly left human | — (correctly HUMAN_DEPENDENT, not a gap) |
| P-16 | Fleet reporting (cross-tenant health for the platform owner) | manual, super-admin console in `app.html` | VERIFIED_WORKING (as a pull, not push) | `muster_admin_overview()` — tenants, users, flags, engine health, pricing, jurisdiction queue all in one call | add push (P-08-style alert) when `failed_24h` engine count crosses a threshold, or a specific tenant goes red | not detailed this pass |

## TENANT / CLIENT PLANE

| ID | Responsibility | Trigger | Current status | Evidence | Desired autonomy | Blocked by |
|---|---|---|---|---|---|---|
| T-01 | Website registration (add a site to monitor) | tenant action in `app.html` | VERIFIED_WORKING | `muster_add_website` RPC | already automated | — |
| T-02 | Scheduled scanning | pg_cron, every 15 min | VERIFIED_WORKING | `muster-scan-due` cron job, `muster-scan` edge function | already automated | — |
| T-03 | On-demand / ad hoc scan | tenant action or agent tool call | VERIFIED_WORKING | `muster_request_scan`, `muster-agent`'s `request_scan` tool | already automated | — |
| T-04 | Evidence collection & finding generation | scan completion | VERIFIED_WORKING | `muster.engine_ingest`, dedupe fingerprint, `scan_evidence`/`findings` tables (docs/BACKEND.md) | already automated | — |
| T-05 | Finding → risk triage & remediation-action creation | every 15 min, `muster.autotriage()` | VERIFIED_WORKING (undocumented — FIND-007) | FIND-007 | already automated; needs to be documented, not re-built | — |
| T-06 | Finding auto-resolve / reopen on rescan (reconciliation) | scan completion | VERIFIED_WORKING | docs/BACKEND.md "Reconciliation — Done for HTTP rules" | already automated for HTTP rules; browser/WCAG rules are Phase 2, correctly NOT_APPLICABLE today | Phase 2 build (browser engine) |
| T-07 | **Notifying the tenant that something changed** (new critical finding, posture band change, scan failure) | none | **MISSING_CONFIRMED** | FIND-008 | this is the top tenant-facing gap — PRD-001 | none — buildable now |
| T-08 | SITREP generation | scan completion | VERIFIED_WORKING | `muster.generate_sitrep()`, deterministic, cited | already automated | — |
| T-09 | SITREP consumption / distribution to stakeholders | tenant manually views or shares `sitrep.html` link | HUMAN_DEPENDENT | `sitrep.html` is a signed-in viewer; no evidence of automatic distribution (e.g. emailing the SITREP to a distribution list on generation) | could be automated (email/PDF on generation) once T-07's channel exists — same underlying gap | T-07 |
| T-10 | Jurisdiction obligation advisory | tenant views in dashboard | VERIFIED_WORKING | `muster_jurisdiction_advisory` | already automated | — |
| T-11 | Finding status management / promotion to risk (manual override) | tenant action | VERIFIED_WORKING | `muster_update_finding_status`, `muster_promote_finding_to_risk` | correctly HUMAN_DEPENDENT — a human deciding a finding's disposition (false positive, accepted risk, etc.) is a judgment call, not a gap | — (appropriately human) |
| T-12 | Team member management (invites, roles) | tenant action | VERIFIED_WORKING | `muster_invite`, `muster_claim_invites` | already automated | — |
| T-13 | Brand/white-label configuration | tenant action | VERIFIED_WORKING | `muster_save_brand`, `brand_profiles` | already automated | — |
| T-14 | Agent/API key issuance for AI-employee integration | tenant action | VERIFIED_WORKING | `muster_create_api_key`/`muster_revoke_api_key`, `muster-agent` gateway | already automated | — |
| T-15 | Lead qualification, CRM, scheduling, inventory, invoicing, aftercare, referrals | — | NOT_APPLICABLE_WITH_EVIDENCE | MUSTER has no customer-facing appointment, inventory, or invoice object in `muster` schema — it is a monitoring/compliance product, not a service-delivery product with those workflows | n/a | — |
| T-16 | Cancellation / offboarding | none found | MISSING_CONFIRMED | no `muster_cancel_org`/offboarding RPC found; `organizations.onboarding_status` exists for the *start* of lifecycle, nothing symmetric for the end | needs a decision: what happens to scan history/evidence on cancellation (retention obligation — see SAFETY doc) before building this | decision needed |
| T-17 | Reactivation / win-back after churn | none found | MISSING_CONFIRMED | no dunning/reactivation logic found | low priority until T-16 and P-03/P-07 exist | T-16, B-1 |

## Coverage denominators (for section 12's reporting requirement, computed now for later use)
- **Total responsibilities identified:** 33 (16 platform + 17 tenant)
- **VERIFIED_WORKING (already zero/appropriately-human autonomous):** 17
- **MISSING_CONFIRMED (real gap, buildable):** 10
- **HUMAN_DEPENDENT by design, correctly so (judgment calls, legal review, release approval):** 3
- **NOT_APPLICABLE_WITH_EVIDENCE:** 2
- **BLOCKED_ACCESS (needs access this audit didn't have):** 1

This denominator will shift once B-1 is resolved (P-03, P-04, P-07, T-16, T-17 all sit downstream of that one decision).
