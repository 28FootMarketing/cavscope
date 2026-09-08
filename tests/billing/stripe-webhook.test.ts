// muster-stripe-webhook: signature verification and event gating, against the
// shipped core.ts.
//
//   node --experimental-strip-types --test tests/billing/stripe-webhook.test.ts
//
// This is the code between anyone on the internet and a free paid plan. It had
// no tests. Two of the cases below are regressions for bugs these tests found.

import { test } from "node:test";
import assert from "node:assert/strict";

import {
  verifyStripeSignature, parseStripeSignatureHeader, timestampWithinTolerance,
  timingSafeEqual, hmacSha256Hex, gateCheckoutSession, MAX_TIMESTAMP_SKEW_SECONDS,
} from "../../supabase/functions/muster-stripe-webhook/core.ts";

const SECRET = "whsec_test_do_not_use_anywhere_real";
const BODY = JSON.stringify({ type: "checkout.session.completed", id: "evt_1" });
const NOW = 1_760_000_000;

/** Build the header Stripe would send for this body at this time. */
async function signedHeader(body = BODY, t = NOW, secret = SECRET): Promise<string> {
  return `t=${t},v1=${await hmacSha256Hex(secret, `${t}.${body}`)}`;
}

test("a genuine Stripe signature verifies", async () => {
  assert.equal(await verifyStripeSignature(BODY, await signedHeader(), SECRET, NOW), true);
});

test("a signature from the wrong secret is refused", async () => {
  const header = await signedHeader(BODY, NOW, "whsec_someone_elses_secret");
  assert.equal(await verifyStripeSignature(BODY, header, SECRET, NOW), false);
});

test("a body altered after signing is refused", async () => {
  const header = await signedHeader();
  const tampered = BODY.replace("evt_1", "evt_2");
  assert.equal(await verifyStripeSignature(tampered, header, SECRET, NOW), false);
});

// The signed payload is `${timestamp}.${body}`, so moving the timestamp without
// re-signing must not verify -- otherwise an old capture could be replayed
// forward simply by editing t.
test("replaying an old body under a fresh timestamp is refused", async () => {
  const old = await signedHeader(BODY, NOW - 10_000);
  const moved = old.replace(`t=${NOW - 10_000}`, `t=${NOW}`);
  assert.equal(await verifyStripeSignature(BODY, moved, SECRET, NOW), false);
});

test("a correctly signed but stale event is refused", async () => {
  const stale = NOW - (MAX_TIMESTAMP_SKEW_SECONDS + 1);
  const header = await signedHeader(BODY, stale);
  assert.equal(await verifyStripeSignature(BODY, header, SECRET, NOW), false);
});

test("the replay window is symmetric, so a little clock skew either way is fine", () => {
  assert.equal(timestampWithinTolerance(String(NOW - MAX_TIMESTAMP_SKEW_SECONDS), NOW), true);
  assert.equal(timestampWithinTolerance(String(NOW + MAX_TIMESTAMP_SKEW_SECONDS), NOW), true);
  assert.equal(timestampWithinTolerance(String(NOW - MAX_TIMESTAMP_SKEW_SECONDS - 1), NOW), false);
  assert.equal(timestampWithinTolerance(String(NOW + MAX_TIMESTAMP_SKEW_SECONDS + 1), NOW), false);
});

test("a junk or missing timestamp is refused rather than coerced", () => {
  for (const t of ["", "abc", "NaN", null]) {
    assert.equal(timestampWithinTolerance(t as string | null, NOW), false, `t=${t}`);
  }
});

test("a header with no v1 at all is refused", async () => {
  assert.equal(await verifyStripeSignature(BODY, `t=${NOW}`, SECRET, NOW), false);
  assert.equal(await verifyStripeSignature(BODY, "", SECRET, NOW), false);
  assert.equal(await verifyStripeSignature(BODY, "garbage", SECRET, NOW), false);
});

// REGRESSION. Stripe sends one v1 per active secret while a webhook signing
// secret is being rotated. The previous implementation parsed the header with
// Object.fromEntries, which keeps only the LAST value for a repeated key -- so
// if our signature was not last, every paid checkout during the rotation window
// was rejected 401, indistinguishable from an attack.
test("a rotation header with several v1 signatures verifies on any position", async () => {
  const ours = await hmacSha256Hex(SECRET, `${NOW}.${BODY}`);
  const other = await hmacSha256Hex("whsec_the_other_secret", `${NOW}.${BODY}`);

  const oursLast = `t=${NOW},v1=${other},v1=${ours}`;
  const oursFirst = `t=${NOW},v1=${ours},v1=${other}`;
  const oursMiddle = `t=${NOW},v1=${other},v1=${ours},v1=${other}`;

  for (const [label, header] of [["last", oursLast], ["first", oursFirst], ["middle", oursMiddle]] as const) {
    assert.equal(await verifyStripeSignature(BODY, header, SECRET, NOW), true,
      `our signature in ${label} position must verify`);
  }
});

test("several v1 signatures, none of them ours, is still refused", async () => {
  const a = await hmacSha256Hex("whsec_a", `${NOW}.${BODY}`);
  const b = await hmacSha256Hex("whsec_b", `${NOW}.${BODY}`);
  assert.equal(await verifyStripeSignature(BODY, `t=${NOW},v1=${a},v1=${b}`, SECRET, NOW), false);
});

test("v0 signatures are ignored, and whitespace in the header is tolerated", async () => {
  const ours = await hmacSha256Hex(SECRET, `${NOW}.${BODY}`);
  const parsed = parseStripeSignatureHeader(`t=${NOW}, v0=deadbeef, v1=${ours}`);
  assert.equal(parsed.timestamp, String(NOW));
  assert.deepEqual(parsed.v1, [ours]);
});

test("timingSafeEqual is exact", () => {
  assert.equal(timingSafeEqual("abc", "abc"), true);
  assert.equal(timingSafeEqual("abc", "abd"), false);
  assert.equal(timingSafeEqual("abc", "abcd"), false);
  assert.equal(timingSafeEqual("", ""), true);
});

// ---------------------------------------------------------------------------
// Event gating
// ---------------------------------------------------------------------------

const paidSession = (over: Record<string, unknown> = {}) => ({
  type: "checkout.session.completed",
  data: {
    object: {
      mode: "subscription",
      payment_status: "paid",
      customer: "cus_1",
      subscription: "sub_1",
      customer_details: { email: "Buyer@Example.COM", name: "A Buyer" },
      metadata: { tier: "muster", stage: "seed" },
      ...over,
    },
  },
});

test("a paid subscription checkout grants, and the email is normalized", () => {
  const g = gateCheckoutSession(paidSession());
  assert.equal(g.act, true);
  if (!g.act) return;
  assert.equal(g.email, "buyer@example.com");
  assert.equal(g.tier, "muster");
  assert.equal(g.stage, "seed");
  assert.equal(g.subscriptionId, "sub_1");
});

// REGRESSION. checkout.session.completed fires when the Checkout Session
// finishes, which is not the same as the money arriving: a delayed-notification
// payment method completes the session with payment_status "unpaid" and can
// still fail afterwards. Granting on completion alone hands a paid plan to
// someone who has not paid and may never.
test("an unpaid completed session grants nothing", () => {
  const g = gateCheckoutSession(paidSession({ payment_status: "unpaid" }));
  assert.equal(g.act, false);
  if (g.act) return;
  assert.equal(g.status, 200, "Stripe must stop retrying; this is a no-op, not an error");
  assert.match(String(g.body.reason), /not paid/);
});

test("a session with no payment_status at all grants nothing", () => {
  const s = paidSession();
  delete (s.data.object as Record<string, unknown>).payment_status;
  const g = gateCheckoutSession(s);
  assert.equal(g.act, false);
});

test("a trial or fully discounted subscription is entitled", () => {
  const g = gateCheckoutSession(paidSession({ payment_status: "no_payment_required" }));
  assert.equal(g.act, true);
});

test("a one-off payment is not a subscription and grants nothing", () => {
  const g = gateCheckoutSession(paidSession({ mode: "payment" }));
  assert.equal(g.act, false);
  if (g.act) return;
  assert.equal(g.status, 200);
});

test("other event types are acknowledged, not errored, so Stripe stops retrying", () => {
  for (const type of ["invoice.paid", "customer.subscription.deleted", "ping"]) {
    const g = gateCheckoutSession({ type, data: { object: {} } });
    assert.equal(g.act, false);
    if (g.act) continue;
    assert.equal(g.status, 200, `${type} must not be a 4xx`);
  }
});

// A Payment Link with no tier/stage metadata is the single most likely
// misconfiguration, and it has to fail loudly: the grant RPC cannot map a plan
// without it.
test("a Payment Link missing tier/stage metadata fails loudly", () => {
  for (const metadata of [{}, { tier: "muster" }, { stage: "seed" }]) {
    const g = gateCheckoutSession(paidSession({ metadata }));
    assert.equal(g.act, false);
    if (g.act) continue;
    assert.equal(g.status, 400, "a silent 200 here would lose a paid customer without a trace");
    assert.match(String(g.body.error), /metadata/);
  }
});

test("a session with no customer email fails loudly", () => {
  const g = gateCheckoutSession(paidSession({ customer_details: { name: "No Email" } }));
  assert.equal(g.act, false);
  if (g.act) return;
  assert.equal(g.status, 400);
});

test("a malformed event does not throw", () => {
  for (const e of [{}, { type: "checkout.session.completed" }, { type: "checkout.session.completed", data: {} }]) {
    assert.doesNotThrow(() => gateCheckoutSession(e));
  }
});
