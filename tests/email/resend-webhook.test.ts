// Contract tests for the Resend webhook's pure half. No network, no database,
// no cost. Imports the shipped module so it cannot drift from what runs.
//
//   node --experimental-strip-types --test tests/email/resend-webhook.test.ts

import { test } from "node:test";
import assert from "node:assert/strict";

import {
  verifySvixSignature,
  signSvixPayload,
  normalizeSecret,
  parseResendEvent,
  mapResendEventType,
  isPermanentBounce,
  SIGNATURE_TOLERANCE_SECONDS,
} from "../../supabase/functions/muster-resend-webhook/core.ts";

// A throwaway base64 secret. Not a credential: it signs nothing real and
// verifies nothing real, it only exercises the HMAC path.
const SECRET = "whsec_" + Buffer.from("muster-test-signing-key-not-a-secret").toString("base64");
const NOW = 1_788_800_000;

function body(overrides: Record<string, unknown> = {}) {
  return JSON.stringify({
    type: "email.delivered",
    created_at: "2026-09-08T05:00:00.000Z",
    data: { email_id: "3f1c0a2e-0000-4000-8000-000000000001", to: ["ops@example.com"] },
    ...overrides,
  });
}

async function signed(raw: string, id = "msg_1", ts = String(NOW)) {
  return { id, timestamp: ts, signature: await signSvixPayload(SECRET, id, ts, raw) };
}

test("a correctly signed payload verifies", async () => {
  const raw = body();
  const h = await signed(raw);
  assert.deepEqual(await verifySvixSignature(SECRET, h, raw, NOW), { ok: true });
});

test("the whsec_ prefix is stripped and quotes tolerated", () => {
  const bare = SECRET.slice(6);
  assert.equal(normalizeSecret(SECRET), bare);
  assert.equal(normalizeSecret(`  "${SECRET}"  `), bare);
  assert.equal(normalizeSecret(bare), bare);
});

test("a tampered body does not verify", async () => {
  const raw = body();
  const h = await signed(raw);
  const tampered = body({ data: { email_id: "attacker-chosen-id", to: ["ops@example.com"] } });
  const r = await verifySvixSignature(SECRET, h, tampered, NOW);
  assert.equal(r.ok, false);
  assert.equal((r as { reason: string }).reason, "signature_mismatch");
});

test("re-serializing the parsed body breaks the signature, which is why the raw string is used", async () => {
  const raw = body();
  const h = await signed(raw);
  const reserialized = JSON.stringify(JSON.parse(raw), ["data", "type", "created_at"]);
  assert.notEqual(reserialized, raw);
  assert.equal((await verifySvixSignature(SECRET, h, reserialized, NOW)).ok, false);
});

test("a signature from a different secret does not verify", async () => {
  const raw = body();
  const other = "whsec_" + Buffer.from("a-different-key-entirely").toString("base64");
  const h = { id: "msg_1", timestamp: String(NOW), signature: await signSvixPayload(other, "msg_1", String(NOW), raw) };
  assert.equal((await verifySvixSignature(SECRET, h, raw, NOW)).ok, false);
});

test("a captured delivery goes stale outside the tolerance window", async () => {
  const raw = body();
  const h = await signed(raw);
  // Inside the window, either direction.
  assert.equal((await verifySvixSignature(SECRET, h, raw, NOW + SIGNATURE_TOLERANCE_SECONDS - 1)).ok, true);
  // Outside it.
  const stale = await verifySvixSignature(SECRET, h, raw, NOW + SIGNATURE_TOLERANCE_SECONDS + 1);
  assert.equal(stale.ok, false);
  assert.equal((stale as { reason: string }).reason, "stale_timestamp");
});

test("missing headers are rejected before any crypto runs", async () => {
  const raw = body();
  for (const h of [
    { id: null, timestamp: String(NOW), signature: "v1,x" },
    { id: "msg_1", timestamp: null, signature: "v1,x" },
    { id: "msg_1", timestamp: String(NOW), signature: null },
  ]) {
    const r = await verifySvixSignature(SECRET, h, raw, NOW);
    assert.equal(r.ok, false);
    assert.equal((r as { reason: string }).reason, "missing_headers");
  }
});

test("a rotation window with several candidate signatures verifies on any match", async () => {
  const raw = body();
  const good = await signSvixPayload(SECRET, "msg_1", String(NOW), raw);
  const h = { id: "msg_1", timestamp: String(NOW), signature: `v1,AAAA ${good} v0,ignored` };
  assert.equal((await verifySvixSignature(SECRET, h, raw, NOW)).ok, true);
});

test("malformed base64 in the signature header does not throw", async () => {
  const raw = body();
  const h = { id: "msg_1", timestamp: String(NOW), signature: "v1,!!!not-base64!!!" };
  const r = await verifySvixSignature(SECRET, h, raw, NOW);
  assert.equal(r.ok, false);
});

test("event types map to what muster.email_events accepts", () => {
  assert.equal(mapResendEventType("email.delivered"), "delivered");
  assert.equal(mapResendEventType("email.bounced"), "bounced");
  assert.equal(mapResendEventType("email.complained"), "complained");
  // Not recorded: no email_id to join on, or not about a message at all.
  assert.equal(mapResendEventType("email.received"), null);
  assert.equal(mapResendEventType("contact.created"), null);
  assert.equal(mapResendEventType("domain.updated"), null);
  assert.equal(mapResendEventType(""), null);
});

test("a well-formed event parses to exactly what the RPC needs", () => {
  const r = parseResendEvent(body());
  assert.equal(r.ok, true);
  const e = (r as { event: Record<string, unknown> }).event;
  assert.equal(e.eventType, "delivered");
  assert.equal(e.providerMessageId, "3f1c0a2e-0000-4000-8000-000000000001");
  assert.deepEqual(e.recipients, ["ops@example.com"]);
  assert.equal(e.occurredAt, "2026-09-08T05:00:00.000Z");
});

test("a single-string recipient is normalised to an array", () => {
  const r = parseResendEvent(body({ data: { email_id: "m1", to: "one@example.com" } }));
  assert.deepEqual((r as { event: { recipients: string[] } }).event.recipients, ["one@example.com"]);
});

test("an event with no email_id is not recordable", () => {
  const r = parseResendEvent(body({ data: { to: ["x@example.com"] } }));
  assert.equal(r.ok, false);
  assert.equal((r as { reason: string }).reason, "missing_email_id");
});

test("unparseable and unmapped payloads are distinguished, because they get different responses", () => {
  assert.equal((parseResendEvent("not json") as { reason: string }).reason, "unparseable");
  assert.equal((parseResendEvent(body({ type: "contact.created" })) as { reason: string }).reason, "unmapped_type");
});

test("a missing or unparseable created_at falls back to now rather than failing", () => {
  for (const raw of [body({ created_at: undefined }), body({ created_at: "not a date" })]) {
    const r = parseResendEvent(raw);
    assert.equal(r.ok, true);
    const at = (r as { event: { occurredAt: string } }).event.occurredAt;
    assert.ok(!Number.isNaN(Date.parse(at)), `occurredAt not a date: ${at}`);
  }
});

test("only a permanent bounce may suppress an address", () => {
  const permanent = parseResendEvent(body({
    type: "email.bounced",
    data: { email_id: "m1", to: ["dead@example.com"], bounce: { type: "Permanent", subType: "General" } },
  }));
  assert.equal(isPermanentBounce((permanent as { event: { detail: Record<string, unknown> } }).event.detail), true);

  const transient = parseResendEvent(body({
    type: "email.bounced",
    data: { email_id: "m1", to: ["full@example.com"], bounce: { type: "Transient", subType: "MailboxFull" } },
  }));
  assert.equal(isPermanentBounce((transient as { event: { detail: Record<string, unknown> } }).event.detail), false);

  // Unclassified bounces fail safe: suppress rather than keep mailing a shared
  // sending domain into an address that already rejected us.
  const unknown = parseResendEvent(body({ type: "email.bounced", data: { email_id: "m1", to: ["x@example.com"] } }));
  assert.equal(isPermanentBounce((unknown as { event: { detail: Record<string, unknown> } }).event.detail), true);
});

test("the recorded detail carries bounce classification and nothing else", () => {
  const r = parseResendEvent(body({
    type: "email.bounced",
    data: {
      email_id: "m1",
      to: ["dead@example.com"],
      bounce: { type: "Permanent", subType: "General", message: "550 5.1.1 user unknown" },
    },
  }));
  const detail = (r as { event: { detail: Record<string, unknown> } }).event.detail;
  assert.deepEqual(Object.keys(detail).sort(), ["bounce_subtype", "bounce_type"]);
  // The provider's free-text reason can quote the original message; it is not
  // stored, so muster.email_events cannot accumulate recipient content.
  assert.equal(JSON.stringify(detail).includes("550"), false);
});
