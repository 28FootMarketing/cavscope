# AUTONOMY-AUDIT — MUSTER

## Headline answer

**Is the no-routine-human-interaction target achieved?** No. Not close, and not because of one big missing feature — because of one specific, well-scoped gap (T-07, no outbound tenant notification) and one unresolved architectural fork (B-1, two half-built checkout paths) that everything downstream of monetization depends on. Outside of those two things, MUSTER's actual scan → finding → risk → SITREP pipeline is more automated than its own documentation claims (FIND-007, the undocumented autotriage cron), which is a rarer and better problem to have than the reverse.

Do not read "more automated than documented" as "fully autonomous." It is not. It is verified-automated for a specific, narrow slice: scanning, finding generation, reconciliation-by-rescan, and risk-register population, for HTTP-based scan rules only, for tenants who already exist. Everything upstream (getting a tenant to paid status) and everything at the edge (telling a tenant something happened, ending a tenant relationship) still has a human or a broken/missing path in it.

## What is genuinely autonomous today (VERIFIED_WORKING, not claimed)

1. Self-serve trial signup → onboarding → first scan, with zero human involvement, code-level verified (FIND-009). This is the actual entry point for the product and it works.
2. Scheduled scanning every 15 minutes via `pg_cron` + `muster-scan` (T-02).
3. Finding generation, dedupe-by-fingerprint, and reconciliation (auto-resolve on rescan, reopen on reappearance) for HTTP-based rules (T-04, T-06).
4. Deterministic, cited SITREP generation on every scan (T-08).
5. Risk-register population and auto-mitigation from findings, every 15 minutes, via the undocumented `muster.autotriage()` (T-05, FIND-007) — this was the single most positive surprise in this audit.
6. Feature-flag/entitlement resolution and plan-based limits (P-05).
7. Security posture on the objects checked: zero unexpected ERROR/WARN advisories on `muster`-owned functions; the "revoke from public isn't enough" lesson from earlier this session is now consistently applied (FIND-005).

## What is claimed automated but is not, or is unverifiable from this audit

1. **Nothing was found to be over-claimed automated in the repo's own documentation** — if anything, `docs/BACKEND.md` under-claims (FIND-007, FIND-004 exist in prod but not in docs). That's worth stating plainly: the failure mode here is documentation drift, not marketing-style overstatement of what the software does.
2. **Self-serve signup's dependency on Supabase Auth dashboard config (Site URL/Redirect URLs)** is asserted correct nowhere and unverifiable via MCP (FIND-009 caveat). Treat "self-serve onboarding: Done" as PRESENT_UNVERIFIED at the infrastructure-config layer even though the code is confirmed correct.

## Human dependencies, ranked by how much revenue/trust rides on them

1. **Every paid conversion requires a human to click "Closed Won" in GHL** (FIND-010). This is the platform's single largest standing human dependency. No compensating alert exists if a rep forgets — a deal can sit Closed Won in GHL indefinitely with the tenant still on `trial` in MUSTER, and nothing surfaces that mismatch (P-04, MISSING_CONFIRMED).
2. **A tenant's only way to learn MUSTER found something critical is to go look** (FIND-008/T-07). This is a human dependency on the *tenant's* side that the product's own premise argues against, and it's the cheapest of the ranked items here to close.
3. **Jurisdiction law corpus maintenance is human research** (P-15) — correctly so; this is legal-judgment work MUSTER should not attempt to automate, and the review-queue surfacing that exists today is the right amount of automation around a properly-human task.
4. **Finding disposition (accept risk / false positive / promote) is a human judgment call** (T-11) — also correctly so.
5. **Release approval (this session's own PR-merge-on-explicit-instruction pattern)** — correctly human, and should stay that way; the gap next to it is CI validation before that human approves, not the approval itself (FIND-011).

## Failures found (not hypotheses — reproduced or directly evidenced)

- Two independent, non-interoperating tenant-provisioning code paths exist in production for the same business event ("new paying tenant") with no reconciliation between them (FIND-004). If both were ever active simultaneously without a decision, a real prospect could end up double-provisioned.
- The repository cannot currently reproduce the live database schema from scratch — at least two deployed migrations have no corresponding file (FIND-003, FIND-004). This is a standing risk to disaster recovery and to anyone else ever working in this repo without full context of what was run directly against Supabase.
- Zero regression protection exists for any claim made about MUSTER in this or any prior session (FIND-011). Every "verified" status in EVIDENCE-REGISTER.md is a snapshot, not a guarantee that holds after the next change.

## What this audit does NOT claim
- It does not claim a percentage of "autonomy achieved." The assignment's own truth contract forbids that, and the honest answer is that the denominator (WORKFLOW-COVERAGE.md's 33 responsibilities) is itself provisional — B-1's resolution will add or remove rows.
- It does not claim the scan engine's 31 rules are individually correct — only that the pipeline wiring around them (scheduling, evidence storage, dedup, reconciliation) is verified. Rule-by-rule correctness was out of scope for this pass (see RUN-STATE.md).
- It does not claim any legal/compliance conclusion about 28FS's own obligations — see SAFETY-AND-APPLICABILITY.md for why that's explicitly out of this audit's authority.
