# PRD-003 — Stripe self-serve checkout for the MUSTER base tier

## Status: IMPLEMENTED and LIVE (2026-09-08)

Resolves BLOCKERS-AND-DECISIONS.md B-1: MUSTER base tier is Stripe self-serve; MUSTER Partner/Enterprise stay GHL sales-assisted (unchanged).

**Both configuration halves confirmed, independently:**
- Stripe side: webhook endpoint `we_1UCXWFJijfcmbDDBlfgn2lQQ` ("muster") registered, live mode, status enabled, URL `https://mgtmqucaldkaxvxglguw.supabase.co/functions/v1/muster-stripe-webhook`, subscribed to `checkout.session.completed`. Confirmed via `STRIPE_LIST_V2_CORE_EVENT_DESTINATIONS`.
- Supabase side: `STRIPE_WEBHOOK_SECRET` is set. Confirmed by probing the live function with a bogus `stripe-signature` header -- it returned `401 {"error":"invalid signature"}`, not the `500 "STRIPE_WEBHOOK_SECRET is not set"` it would return if the secret were missing.

**Not performed, by explicit decision:** a real end-to-end live purchase (pay -> webhook fires -> grant recorded -> onboarding applies the plan). Anthony chose to ship on the strength of the piece-by-piece verification above rather than run a real live-mode charge to prove the full chain. This is a genuine, accepted residual gap, not a false "fully verified" claim -- if the first real customer purchase doesn't flow through correctly, check (in order): the webhook endpoint's recent delivery attempts in the Stripe dashboard, `muster.pending_commercial_grants` for a matching row, and `muster.do_onboard`'s grant-lookup query.

## What was built

**Design choice, stated explicitly:** this does NOT resurrect `muster.onboard_client` (dead since 2026-09-06, unreachable, and independently buggy -- inserts an `organization_members.role` value the live check constraint rejects; see migration `20260906012143`'s header). Instead it teaches the existing, already-verified, already-live self-serve onboarding wizard (`muster_onboard` -> `muster.do_onboard`, FIND-009) to recognize a payment made before signup. Net-new surface is small: one table, one RPC, one small addition to an existing function, one new edge function. No parallel onboarding path was built.

1. **Live Stripe objects** (created via the connected Composio Stripe integration, confirmed live/production account `acct_1PUDj1JijfcmbDDB`, not a sandbox -- confirmed with Anthony before writing):
   - Product `prod_VCwq3MBRwc16WC` ("MUSTER")
   - Price `price_1UCWx0JijfcmbDDBLEFrn3Et` -- seed, $97/mo
   - Price `price_1UCWx0JijfcmbDDBKaHbJyGW` -- fruit, $197/mo
   - Payment Link `https://buy.stripe.com/eVqbJ26yL2hw3gL2x3gIo0t` (seed), metadata `{tier: muster, stage: seed}`
   - Payment Link `https://buy.stripe.com/bJeeVe5uHaO2bNhb3zgIo0u` (fruit), metadata `{tier: muster, stage: fruit}`
   - Both redirect to `https://app.muster.28footsystems.com/?checkout=success` on completion.

2. **`supabase/migrations/20260908010000_muster_stripe_selfserve_checkout.sql`**:
   - `muster.pending_commercial_grants` (email, plan, stage, stripe_customer_id, stripe_subscription_id, created_at, applied_at) with a partial unique index on `lower(email) where applied_at is null` -- at most one unapplied grant per email.
   - `public.muster_engine_record_commercial_grant(p_email, p_tier, p_stage, p_stripe_customer_id, p_stripe_subscription_id)` -- service_role only, resolves `plan` via `commercial_pricing.maps_to_plan`, upserts the pending grant.
   - `muster.do_onboard` extended: right after the organization + membership rows are created (before the first website is added, so a plan-derived website_limit is already correct), it looks up a pending grant for the new user's email and, if found, applies `plan`/`website_limit`/`commercial_stage` and marks the grant applied. Everything else in the function is byte-for-byte the same as before this change.
   - `commercial_pricing.stripe_price_id` backfilled for `muster`/seed and `muster`/fruit (the two rows this tier actually needs). `muster_partner` rows correctly stay null -- that tier isn't Stripe.

3. **`supabase/functions/muster-stripe-webhook/index.ts`** (new, deployed, ACTIVE): verifies the `Stripe-Signature` header (manual HMAC-SHA256 per Stripe's documented scheme against the raw body, 300-second replay tolerance, timing-safe compare -- no Stripe SDK dependency, consistent with this repo's existing style), handles `checkout.session.completed` for `mode=subscription` only, reads `customer_details.email/name` and `metadata.tier/stage` directly off the event (no second Stripe API call needed -- tier/stage/price already ride along as Payment-Link-level metadata), invites the Supabase Auth user via `muster_find_auth_user_by_email` + `inviteUserByEmail` if new, then calls `muster_engine_record_commercial_grant`. Every non-matching event type returns 200 (acknowledged no-op, not an error Stripe would retry forever).

4. **`index.html`**: base-tier CTA now points at the correct Payment Link for the current pricing stage (replacing the placeholder `forms.your-ghl-domain.example.com` GHL URL that was never real). Partner CTA untouched, still the GHL placeholder -- that one remains a real, separate gap, out of scope for this PRD.

## Verification performed
- `node --check` on `index.html`'s extracted script: clean.
- Migration applied live without error; `muster.do_onboard`'s diff against the pre-change version confirmed byte-for-byte identical apart from the inserted grant-check block.
- Edge function deployed, status ACTIVE.
- **Not yet performed** (blocked on the residual item above): a real end-to-end Stripe checkout -> webhook -> onboarding-applies-grant test. Cannot be run responsibly until the webhook endpoint + secret exist, since without them the webhook will 500 on every real attempt. Once Anthony completes that step, the test is: pay via one Payment Link with a real card, confirm the webhook fires (Stripe dashboard shows a 200), confirm a `muster.pending_commercial_grants` row appears, complete onboarding as that user in `app.html`, confirm the resulting org's `plan`/`commercial_stage` match the tier paid for (not `trial`).

## Rollback
```sql
alter table muster.commercial_pricing set stripe_price_id = null where tier = 'muster';
drop function if exists public.muster_engine_record_commercial_grant(text, text, text, text, text);
drop table if exists muster.pending_commercial_grants;
-- revert muster.do_onboard to the pre-PRD-003 version (docs/BACKEND.md history / git blame on this migration) if the grant-check block needs removing independently.
```
Stripe-side: deactivate (do not delete) the two Payment Links and the two Prices via the dashboard or `STRIPE_UPDATE_PAYMENT_LINK`/price `active: false` if this path is ever abandoned -- Stripe does not allow deleting Prices once created.
