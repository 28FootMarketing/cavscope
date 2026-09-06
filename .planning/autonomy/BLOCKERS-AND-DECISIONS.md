# BLOCKERS-AND-DECISIONS — MUSTER

Decisions only Anthony can make. Nothing here is resolved by guessing or by picking the option that makes the automation percentage look better.

---

## B-1 — GHL sales-assisted checkout vs. Stripe self-serve checkout vs. both

**What's actually deployed (verified, FIND-004, FIND-010):**
- **Path A (GHL, working):** `muster-ghl-webhook` edge function, live, git-tracked, tested end-to-end this session. Fires only when a human sales rep marks a GHL deal "Closed Won." Provisions via `public.muster_ghl_provision`.
- **Path B (Stripe, dead):** `muster.onboard_client()` RPC, live in the database, **not in git**, built to be called by a `muster-stripe-webhook` edge function that does not exist. `commercial_pricing.stripe_price_id` is null on every row, so even if wired up today it would immediately fail. No human is involved in this path by design — it's meant to be self-serve.

**Why this can't be silently resolved:** These two paths represent two different commercial models for the same product tier. Path A implies every MUSTER/MUSTER Partner sale goes through a sales conversation in GHL. Path B implies a prospect can self-serve straight to a paid plan with a credit card, no sales conversation at all. Building automation on top of either one, without knowing which one is supposed to survive, means rebuilding it when the real answer surfaces.

**Options:**
1. **GHL-only.** Delete/deprecate the dead Stripe schema (`muster.onboard_client`, `maps_to_plan`, the unique index) with a migration, keep everything sales-assisted. Simplest, matches what's actually working today.
2. **Stripe-only for the base `muster` tier, GHL for `muster_partner`/`muster_enterprise`.** Finish the Stripe path (build `muster-stripe-webhook`, populate `stripe_price_id`), keep GHL for the higher-touch tiers. Matches how the pricing page CTAs already read (base tier looks self-serve-shaped; Partner/Enterprise look sales-shaped).
3. **Both, for every tier, with a reconciliation rule.** Highest engineering cost — needs a rule for what happens if a contact enters both funnels (e.g. a Stripe self-serve signup while a GHL deal for the same email is also open).

**Recommendation if asked directly:** Option 2. The pricing page you already approved this session treats MUSTER (base) as a self-serve product (a plain "sign up" CTA, no "talk to sales" framing) and MUSTER Partner as a higher-touch relationship (reseller economics, "Founding Partner" language). Finishing the Stripe path only for the base tier matches that framing and removes the only remaining human step from your lowest-value, highest-volume tier, while keeping a human in the loop exactly where deal-specific negotiation (Partner org limits, custom pricing) actually needs one.

**What's blocked until this is decided:** PRD-002 (checkout automation) is not written in this pass because it would be guessing which path to finish. P-03, P-04, P-07, T-16, T-17 in WORKFLOW-COVERAGE.md all sit downstream of this.

**What's NOT blocked:** everything else in this program, including PRD-001 (critical-finding alerts), which is independent of the checkout question and detailed in full below.

---

## B-2 — RESOLVED (2026-09-08): Resend, email

Anthony confirmed Resend. Implementation found that `RESEND_API_KEY` already exists as a project-wide Edge Function secret (pre-existing, not set by this work) and `mail.28footsystems.com` is already a verified Resend sending domain -- used as `alerts@mail.28footsystems.com`. PRD-001 is implemented and live (see PRD file for status). One residual item: a new sending-only, domain-restricted Resend API key (`muster-alert-dispatch`, ID `9d3ac8ce-bbe9-426d-b50a-6d67bfb38313`) was created during implementation but is **not yet in use** -- the pre-existing, broader-scoped project-wide key is what actually sent, because there is no MCP tool available to change an Edge Function's secret value. **Action for Anthony:** in the Supabase dashboard, Edge Functions -> Secrets for project `mgtmqucaldkaxvxglguw`, consider pointing `RESEND_API_KEY` at the new scoped key instead (least privilege -- sending-only, restricted to `mail.28footsystems.com`) if the existing key's scope is broader than it needs to be for this use. The scoped key's token was shown once at creation time in this session's chat transcript.

## B-2 (original text, retained for context) — Tenant notification channel(s) for PRD-001

PRD-001 (critical-finding alerts) needs at least one real delivery channel. Candidates already present in your stack per your profile: Resend (email — you have an MCP connector for it), Telegram/CORA (chat 1238597047 is your own ops channel, not a tenant's), Twilio-class SMS (not seen configured anywhere in this project). A tenant-facing alert should almost certainly be **email**, addressed to the org's admin/member list, not Telegram/CORA (that's your internal ops channel, not a customer-facing one) and not SMS unless a tenant opts in and TCPA-style consent is captured (see SAFETY-AND-APPLICABILITY.md).

**Decision needed:** confirm email-via-Resend as the v1 channel for PRD-001, and confirm the "from" address / domain to send as (must be a domain you control with SPF/DKIM set up, or Resend will land in spam and the whole point of the alert is defeated). PRD-001 below is written assuming this answer is "yes, Resend, email" — flag if that's wrong before implementation starts.

---

## B-3 — Tenant offboarding / cancellation data retention

T-16 (cancellation) can't be built without knowing how long scan evidence, findings, and SITREPs must be retained after a tenant cancels — this is a retention-policy decision, not an engineering one, and depends on what commitments (if any) you've made to tenants about audit-trail retention. Not detailed further in this pass; flagged so it doesn't get silently skipped.

---

## B-4 — Support ticketing ownership (P-08)

Is tenant support for MUSTER handled through the separate `isupport` product already in this Supabase project, through GHL, or not yet decided? Affects whether P-08 is "wire up an existing system" (cheap) or "decide to build one" (not cheap, and probably not the next priority).
