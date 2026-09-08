import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { gateCheckoutSession, verifyStripeSignature } from "./core.ts";

// PRD-003: Stripe self-serve checkout for the base MUSTER tier only.
// MUSTER Partner/Enterprise stay sales-assisted via muster-ghl-webhook
// (BLOCKERS-AND-DECISIONS.md B-1). Does not use muster.onboard_client
// (dead, buggy -- see migration 20260906012143's header). Instead: this
// function only records that a real payment happened (invites the auth
// user if new, records a pending plan grant keyed by email) and the
// EXISTING, already-verified self-serve onboarding wizard in app.html
// (muster_onboard -> muster.do_onboard) picks the grant up the moment the
// user actually creates their organization -- no parallel onboarding path.
//
// That handoff is verified: a probe run against the live database recorded a
// grant, ran do_onboard, and saw the organization come out as plan=starter,
// commercial_stage=seed, website_limit 1 -> 3, with the grant marked applied so
// a second organization cannot claim it again.
//
// Required Edge Function secret: STRIPE_WEBHOOK_SECRET (the signing
// secret for the webhook endpoint registered in the Stripe dashboard --
// Developers -> Webhooks -> Add endpoint, pointed at this function's URL,
// subscribed to checkout.session.completed; the secret is revealable there
// at any time, not only at creation).
// Nothing else needs a Stripe API key: tier/stage/price id all arrive as
// Payment-Link-level metadata already present on the event payload, so
// this function never calls back into Stripe's API. A Payment Link with no
// tier/stage metadata is rejected 400 -- that is the configuration to check
// first if a real checkout ever fails here.
//
// Signature verification and event gating live in core.ts, under test.

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const webhookSecret = Deno.env.get("STRIPE_WEBHOOK_SECRET");
  if (!webhookSecret) return json({ error: "STRIPE_WEBHOOK_SECRET is not set" }, 500);

  const signatureHeader = req.headers.get("stripe-signature");
  // The RAW body, never re-serialized JSON: the HMAC is over the exact bytes
  // Stripe signed, and JSON.parse followed by JSON.stringify does not reproduce
  // them.
  const rawBody = await req.text();
  if (!signatureHeader || !(await verifyStripeSignature(rawBody, signatureHeader, webhookSecret))) {
    return json({ error: "invalid signature" }, 401);
  }

  let event: { type?: string; data?: { object?: Record<string, unknown> } } = {};
  try {
    event = JSON.parse(rawBody);
  } catch {
    return json({ error: "invalid JSON body" }, 400);
  }

  const gate = gateCheckoutSession(event);
  if (!gate.act) return json(gate.body, gate.status);

  const { data: existingAuthId, error: lookupErr } = await db.rpc("muster_find_auth_user_by_email", { p_email: gate.email });
  if (lookupErr) return json({ error: `auth lookup failed: ${lookupErr.message}` }, 500);

  let invited = false;
  if (!existingAuthId) {
    const { error: inviteErr } = await db.auth.admin.inviteUserByEmail(gate.email, {
      data: { name: gate.name || undefined, source: "stripe_checkout" },
    });
    // A 422/"already registered" race here is fine -- the grant below is
    // keyed by email, not by the invite outcome, so onboarding still finds
    // it regardless of exactly how the auth user came to exist.
    if (inviteErr) {
      const alreadyExists = /already been registered|already exists/i.test(inviteErr.message ?? "");
      if (!alreadyExists) return json({ error: `could not create account: ${inviteErr.message}` }, 500);
    } else {
      invited = true;
    }
  }

  const { error: grantErr } = await db.rpc("muster_engine_record_commercial_grant", {
    p_email: gate.email,
    p_tier: gate.tier,
    p_stage: gate.stage,
    p_stripe_customer_id: gate.customerId,
    p_stripe_subscription_id: gate.subscriptionId,
  });
  if (grantErr) return json({ error: `could not record commercial grant: ${grantErr.message}` }, 400);

  return json({ received: true, handled: true, invited });
});
