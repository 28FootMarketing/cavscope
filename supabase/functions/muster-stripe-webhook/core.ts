// The parts of the Stripe webhook that are decidable without a network call or
// a database, extracted so they can be tested. index.ts keeps the I/O.
//
// This is the code standing between anyone on the internet and a free paid
// plan, and until now it had no tests at all. Everything below is a function of
// its arguments.

export const MAX_TIMESTAMP_SKEW_SECONDS = 300; // Stripe's own recommended replay tolerance

/**
 * Constant-time-ish comparison. Returns early on a length mismatch, which leaks
 * length only -- both operands here are fixed-width hex digests, so that leaks
 * nothing an attacker does not already know.
 */
export function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let mismatch = 0;
  for (let i = 0; i < a.length; i++) mismatch |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return mismatch === 0;
}

export async function hmacSha256Hex(secret: string, payload: string): Promise<string> {
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

/**
 * Parse a Stripe-Signature header into its timestamp and its v1 signatures.
 *
 * Note the plural. Stripe sends MORE THAN ONE v1 when a webhook secret is being
 * rotated -- one per active secret -- and the previous implementation built the
 * header with Object.fromEntries, which silently keeps only the last value for a
 * repeated key. If the signature computed from our secret was not the last one
 * in the header, every event during the rotation window would have been
 * rejected as an invalid signature: paid checkouts dropped on the floor, with a
 * 401 that looks exactly like an attack.
 *
 * v0 signatures are for Stripe's own test tooling and are deliberately ignored.
 */
export function parseStripeSignatureHeader(header: string): { timestamp: string | null; v1: string[] } {
  let timestamp: string | null = null;
  const v1: string[] = [];
  for (const part of String(header || "").split(",")) {
    const idx = part.indexOf("=");
    if (idx < 0) continue;
    const key = part.slice(0, idx).trim();
    const value = part.slice(idx + 1).trim();
    if (key === "t" && timestamp === null) timestamp = value;
    else if (key === "v1" && value) v1.push(value);
  }
  return { timestamp, v1 };
}

/** True when the timestamp is present, numeric, and inside the replay window. */
export function timestampWithinTolerance(timestamp: string | null, nowSeconds: number): boolean {
  if (!timestamp) return false;
  const t = Number(timestamp);
  if (!Number.isFinite(t)) return false;
  return Math.abs(nowSeconds - t) <= MAX_TIMESTAMP_SKEW_SECONDS;
}

export async function verifyStripeSignature(
  rawBody: string,
  header: string,
  secret: string,
  nowSeconds: number = Date.now() / 1000,
): Promise<boolean> {
  const { timestamp, v1 } = parseStripeSignatureHeader(header);
  if (!timestamp || v1.length === 0) return false;
  if (!timestampWithinTolerance(timestamp, nowSeconds)) return false;

  const expected = await hmacSha256Hex(secret, `${timestamp}.${rawBody}`);
  // Every candidate is checked; one match is enough. The loop does not break
  // early on success, so the work done does not depend on which one matched.
  let ok = false;
  for (const candidate of v1) {
    if (timingSafeEqual(expected, candidate)) ok = true;
  }
  return ok;
}

export type GateResult =
  | { act: false; status: number; body: Record<string, unknown> }
  | { act: true; email: string; name: string; tier: string; stage: string;
      customerId: string | null; subscriptionId: string | null };

/**
 * Decide whether an event should grant a plan, and pull out what the grant
 * needs. Returns the exact response to send when it should not.
 *
 * The payment_status check is the one that matters commercially.
 * checkout.session.completed fires when the Checkout Session finishes, which is
 * NOT the same as the money arriving. With a delayed-notification payment
 * method the session completes with payment_status "unpaid" and the payment may
 * still fail afterwards -- so recording the grant on completion alone hands out
 * a paid plan to someone who has not paid, and may never.
 *
 *   paid                  the money is in
 *   no_payment_required   a trial or a 100% coupon; legitimately entitled
 *   unpaid                not yet, and possibly never -- wait for
 *                         checkout.session.async_payment_succeeded
 */
const ENTITLING_PAYMENT_STATUS = new Set(["paid", "no_payment_required"]);

export function gateCheckoutSession(
  event: { type?: string; data?: { object?: Record<string, unknown> } },
): GateResult {
  const ok = (body: Record<string, unknown>) => ({ act: false as const, status: 200, body });
  const bad = (status: number, body: Record<string, unknown>) => ({ act: false as const, status, body });

  // Every other event type is acknowledged 200, not treated as an error, so
  // Stripe does not retry it forever. Explicitly a no-op, not a miss.
  if (event.type !== "checkout.session.completed") {
    return ok({ received: true, handled: false });
  }

  const session = event.data?.object ?? {};
  if (session["mode"] !== "subscription") {
    return ok({ received: true, handled: false, reason: "non-subscription session" });
  }

  const paymentStatus = String(session["payment_status"] ?? "");
  if (!ENTITLING_PAYMENT_STATUS.has(paymentStatus)) {
    // 200, not an error: the session is real and Stripe should stop retrying.
    // If the money lands later it arrives as its own event.
    return ok({
      received: true, handled: false,
      reason: `payment_status is "${paymentStatus || "absent"}", not paid`,
    });
  }

  const customerDetails = (session["customer_details"] as Record<string, unknown> | null) ?? {};
  const email = String(customerDetails["email"] ?? "").trim().toLowerCase();
  const name = String(customerDetails["name"] ?? "").trim();
  const metadata = (session["metadata"] as Record<string, string> | null) ?? {};
  const tier = metadata["tier"];
  const stage = metadata["stage"];

  if (!email) return bad(400, { error: "session has no customer email" });
  if (!tier || !stage) return bad(400, { error: "session metadata missing tier/stage" });

  return {
    act: true, email, name, tier, stage,
    customerId: (session["customer"] as string | null) ?? null,
    subscriptionId: (session["subscription"] as string | null) ?? null,
  };
}
