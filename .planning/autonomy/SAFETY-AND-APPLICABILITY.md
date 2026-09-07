# SAFETY-AND-APPLICABILITY — MUSTER

This is a scoped first pass, not a completed legal/security clearance. It identifies what's actually relevant to MUSTER specifically and marks what requires counsel or a decision this audit cannot make. It does not fabricate a jurisdiction matrix, a threat model with invented severities, or a legal conclusion — where the assignment asks for those and this audit lacks the authority or evidence to produce them honestly, that is stated plainly below rather than filled in.

## The distinction that matters most here, stated explicitly
MUSTER's own product feature (`muster.jurisdictions`/`jurisdiction_laws`, the "jurisdiction advisor") tells **tenants** about privacy/accessibility/security law that applies to *their* website. That is a product capability, and its output should already read as informational, not as legal advice on 28FS's behalf — this audit did not verify whether `app.html`/`sitrep.html` carry an explicit "not legal advice" disclaimer anywhere in the rendered UI; this is a two-minute check that was not performed in this pass and should be, given the jurisdiction-advisor feature exists specifically to make legal-sounding claims.

Separately, **28FS itself**, as the operator processing tenant website data, has its own obligations (data handling, retention, breach response) that are not the same question and are not answered by anything MUSTER's jurisdiction advisor produces. This audit does not have counsel authority and does not attempt a jurisdiction matrix for 28FS's own obligations — that requires a lawyer, not a code audit. What follows is only what's directly observable from the codebase and relevant to that question, not a legal conclusion.

## Data handled and where it could carry sensitivity
- **Scan evidence** (`muster.scan_evidence`, per docs/BACKEND.md: "redirect chain, primary response, header set, HTTP probe, robots.txt, sitemap, security.txt, HTML excerpts") is captured from the **tenant's own public website**, not from end-customers directly. It could incidentally contain PII if a tenant's own page exposes it (a contact form's static HTML, an email address in a footer, etc.) — this is inherent to being a website scanner and is a much lower-sensitivity profile than a product that processes end-user accounts or payments directly.
- No payment/card data exists in the `muster` schema — billing lives entirely outside it (GHL/Stripe), which is the correct minimization choice already in effect, though it also means reconciliation between "money moved" and "org state changed" has no ledger to reconcile against yet (WORKFLOW-COVERAGE P-04, P-07).
- No embeddings exist for any of this data (FIND-012 — pgvector unused today), so the assignment's "never put unnecessary sensitive records into embeddings" concern is currently NOT_APPLICABLE_WITH_EVIDENCE. This becomes directly relevant the moment Phase 3 (pgvector over `scan_evidence.excerpt`/`sitreps.content_md`, per docs/BACKEND.md's own roadmap) is built — flag now so that build starts with minimization/redaction designed in, not retrofitted.

## Consent and contact controls
- The `muster-ghl-webhook` provisioning flow (this session's own work) sends no marketing communication itself — it provisions a tenant after a human-driven GHL deal closes. Any marketing/nurture sequencing that runs *inside* GHL before that point is entirely outside this repo's visibility and this audit's evidence — not verified either way.
- PRD-001's alert emails (this pass's proposal) are transactional, sent only to existing org members with `executive`/`risk_owner` roles about that org's own monitored website — this is implied-consent territory (an org member being told about their own organization's risk finding), materially different from a cold marketing send, and includes an explicit per-org opt-out (`critical_alerts_enabled`) as the control that actually matters for a transactional alert.
- **Not evaluated in this pass:** whether any tenant-facing SMS capability exists or is planned (none found in this repo) — if one is ever added, it needs the same consent-capture rigor the assignment describes (explicit basis, timestamp, revocation, quiet hours) before a single message goes out, and that is a materially higher bar than the email case above.

## AI tool security (the `muster-agent` gateway)
- Verified from code (docs/BACKEND.md, migration files): API keys are stored as SHA-256 hashes, scoped (`read`/`scan`/`write`/`admin`), org-scoped keys are claimed to be unable to reach other tenants, platform keys (org null) are super-admin-issued.
- **Not verified by this audit:** no live negative test was run this pass to confirm an org-scoped key actually cannot read another org's findings/evidence through the MCP gateway. This is exactly the kind of "PRESENT_UNVERIFIED, not PASS" distinction the assignment insists on. Recommended acceptance test for a future pass: issue two API keys for two different test orgs, attempt every read tool (`list_websites`, `get_evidence`, etc.) from org A's key against org B's website/finding IDs, confirm every attempt is denied, not merely filtered.
- The gateway's tool set is registered/typed (`list_websites`, `website_overview`, etc., per docs/BACKEND.md) rather than arbitrary SQL/shell access — this matches the assignment's "registered tools, typed arguments" requirement by construction, not by an add-on filter.

## Guardrail register (what exists vs. what's asserted)
| Control | Enforcement point | Status |
|---|---|---|
| Tenant isolation (RLS on every `muster.*` table) | Postgres RLS, `muster.is_org_member`/`can_write_org`/`is_org_executive` | VERIFIED_WORKING per docs + this session's advisor checks (FIND-005, FIND-006) |
| service_role functions unreachable by anon/authenticated | explicit `revoke ... from public, anon, authenticated` on every `muster_engine_*`/`muster_admin_*`/`muster_ghl_*` function | VERIFIED_WORKING (FIND-005) |
| Org-scoped API key cross-tenant denial | `muster-agent` gateway auth logic | PRESENT_UNVERIFIED (see above — no live negative test run) |
| Alert dispatch idempotency (no duplicate sends per risk) | `notification_outbox` unique index (PRD-001 Task 1) | PROPOSED, not yet built |
| Per-org critical-alert kill switch | `organizations.critical_alerts_enabled` (PRD-001 Task 2) | PROPOSED, not yet built |
| CI-enforced regression protection | none | MISSING_CONFIRMED (FIND-011); PRD-004 proposed |
| Legal-claim disclaimer on jurisdiction-advisor output | unknown — not checked this pass | UNKNOWN, two-minute check outstanding |

## What this audit explicitly refuses to fabricate
- A jurisdiction/applicability matrix for 28FS's own regulatory obligations (requires counsel; this audit has no authority to produce one and will not guess).
- A threat-model severity score for hazards not directly observed (e.g., "what happens if a prompt-injected scan evidence excerpt reaches `muster-agent`'s tool outputs" — plausible concern given the gateway surfaces `get_evidence` to an LLM client, but no test was run this pass to establish whether raw HTML excerpts are sanitized/encoded before being returned to an MCP client. Flagged as UNKNOWN, not scored.)
- An adversarial test suite result — none was run. Building and running one (per assignment section 12) is future work, not claimed complete here.
