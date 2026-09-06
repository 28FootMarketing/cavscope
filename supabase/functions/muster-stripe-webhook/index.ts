import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

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
// Required Edge Function secret: STRIPE_WEBHOOK_SECRET (the signing
// secret Stripe shows once when the webhook endpoint is registered in the
// Stripe dashboard -- Developers -> Webhooks -> Add endpoint, pointed at
// this function's URL, subscribed to checkout.session.completed).
// Nothing else needs a Stripe API key: tier/stage/price id all arrive as
// Payment-Link-level metadata already present on the event payload, so
// this function never calls back into Stripe's API.
//
// Verifies the Stripe-Signature header per Stripe's documented HMAC-SHA256
// scheme against the RAW request body (never the re-serialized JSON).

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

const MAX_TIMESTAMP_SKEW_SECONDS = 300; // Stripe's own recommended replay tolerance

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let mismatch = 0;
  for (let i = 0; i < a.length; i++) mismatch |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return mismatch === 0;
}

async function hmacSha256Hex(secret: string, payload: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(payload));
  return Array.from(new Uint8Array(sig)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function verifyStripeSignature(rawBody: string, header: string, secret: string): Promise<boolean> {
  const parts = Object.fromEntries(header.split(",").map((p) => p.split("=")) as [string, string][]);
  const timestamp = parts["t"];
  const v1 = parts["v1"];
  if (!timestamp || !v1) return false;

  const ageSeconds = Math.abs(Date.now() / 1000 - Number(timestamp));
  if (!Number.isFinite(ageSeconds) || ageSeconds > MAX_TIMESTAMP_SKEW_SECONDS) return false;

  const expected = await hmacSha256Hex(secret, `${timestamp}.${rawBody}`);
  return timingSafeEqual(expected, v1);
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const webhookSecret = Deno.env.get("STRIPE_WEBHOOK_SECRET");
  if (!webhookSecret) return json({ error: "STRIPE_WEBHOOK_SECRET is not set" }, 500);

  const signatureHeader = req.headers.get("stripe-signature");
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

  // Only checkout.session.completed matters for this flow. Every other
  // event type is acknowledged 200 (not 404/ignored-as-error) so Stripe
  // does not retry it forever -- explicitly a no-op, not a miss.
  if (event.type !== "checkout.session.completed") {
    return json({ received: true, handled: false });
  }

  const session = event.data?.object ?? {};
  const mode = session["mode"] as string | undefined;
  if (mode !== "subscription") {
    return json({ received: true, handled: false, reason: "non-subscription session" });
  }

  const customerDetails = (session["customer_details"] as Record<string, unknown> | null) ?? {};
  const email = String(customerDetails["email"] ?? "").trim().toLowerCase();
  const name = String(customerDetails["name"] ?? "").trim();
  const metadata = (session["metadata"] as Record<string, string> | null) ?? {};
  const tier = metadata["tier"];
  const stage = metadata["stage"];
  const customerId = session["customer"] as string | null;
  const subscriptionId = session["subscription"] as string | null;

  if (!email) return json({ error: "session has no customer email" }, 400);
  if (!tier || !stage) return json({ error: "session metadata missing tier/stage" }, 400);

  const { data: existingAuthId, error: lookupErr } = await db.rpc("muster_find_auth_user_by_email", { p_email: email });
  if (lookupErr) return json({ error: `auth lookup failed: ${lookupErr.message}` }, 500);

  let invited = false;
  if (!existingAuthId) {
    const { error: inviteErr } = await db.auth.admin.inviteUserByEmail(email, {
      data: { name: name || undefined, source: "stripe_checkout" },
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
    p_email: email,
    p_tier: tier,
    p_stage: stage,
    p_stripe_customer_id: customerId,
    p_stripe_subscription_id: subscriptionId,
  });
  if (grantErr) return json({ error: `could not record commercial grant: ${grantErr.message}` }, 400);

  return json({ received: true, handled: true, invited });
});
