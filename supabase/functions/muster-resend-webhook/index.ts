import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import {
  parseResendEvent,
  verifySvixSignature,
  isPermanentBounce,
} from "./core.ts";

// Inbound Resend webhook for CavScope application email.
//
// This is what makes the difference between "accepted for sending" and
// "delivered" observable. muster-alert-dispatch records the id Resend returns
// from POST /emails; Resend later calls here with what actually happened, and
// public.muster_engine_record_email_event joins the two.
//
// verify_jwt = false in config.toml. Authentication IS the Svix signature --
// there is no other credential, which is why an unsigned or stale request is
// rejected before anything is parsed or written.
//
// Two properties this endpoint depends on, both easy to get wrong:
//
//   1. The signature covers the RAW body. req.text() once, verify that string,
//      parse that same string. Re-serializing the parsed JSON changes key order
//      and the signature will never match again.
//
//   2. Resend webhooks are account-wide, not per-domain. This one Resend
//      account also carries BRD, GFFH and the 28FS domains, so most deliveries
//      reaching this URL are about somebody else's mail. Those are answered 200
//      and written nowhere: the RPC matches on provider_message_id against
//      CavScope's own outbox and returns matched=false for everything else.
//
// Retry contract with Resend: 2xx means "do not send this again". So anything
// that is merely uninteresting (a foreign message, an unmapped event type, a
// replay) answers 200. Only a genuine server-side fault answers 5xx, because
// only that is worth redelivering. An invalid signature answers 401 and is
// never retried into success.

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const secret = Deno.env.get("RESEND_WEBHOOK_SECRET");
  if (!secret) {
    // Fail closed and loudly. Accepting unverified events would let anyone who
    // finds this URL mark a real alert delivered or suppress a tenant's address.
    console.error("RESEND_WEBHOOK_SECRET is not set; rejecting");
    return json({ error: "webhook is not configured" }, 500);
  }

  const rawBody = await req.text();
  const verdict = await verifySvixSignature(secret, {
    id: req.headers.get("svix-id"),
    timestamp: req.headers.get("svix-timestamp"),
    signature: req.headers.get("svix-signature"),
  }, rawBody);

  if (!verdict.ok) {
    // The reason is logged; the response does not name it. Telling a caller
    // whether the secret or the timestamp was wrong is free reconnaissance.
    console.error(`resend webhook rejected: ${verdict.reason}`);
    return json({ error: "invalid signature" }, 401);
  }

  const svixId = req.headers.get("svix-id")!;
  const parsed = parseResendEvent(rawBody);
  if (!parsed.ok) {
    if (parsed.reason === "unparseable") return json({ error: "invalid payload" }, 400);
    // A contact.*, domain.* or email.received event, or one with no email_id.
    // Not ours to record, and not a failure worth retrying.
    return json({ received: true, recorded: false, reason: parsed.reason });
  }

  const { eventType, providerMessageId, occurredAt, recipients, detail } = parsed.event;

  // A soft bounce (full mailbox, greylisting) is recorded but must not retire
  // the address. Only a permanent bounce is allowed to suppress, so the
  // recipient list handed to the RPC is empty for transient ones.
  const suppressible = eventType === "complained" ||
    (eventType === "bounced" && isPermanentBounce(detail));

  const { data, error } = await db.rpc("muster_engine_record_email_event", {
    p_idempotency_key: `svix-${svixId}`,
    p_provider_message_id: providerMessageId,
    p_event_type: eventType,
    p_occurred_at: occurredAt,
    p_recipients: suppressible ? recipients : [],
    p_detail: detail,
  });

  if (error) {
    // A real fault. 5xx so Resend redelivers; the unique idempotency key makes
    // that redelivery safe.
    console.error(`record_email_event failed for ${providerMessageId}: ${error.message}`);
    return json({ error: "could not record event" }, 500);
  }

  const result = (data ?? {}) as Record<string, unknown>;

  // Operational log line. Carries the provider message id, the internal outbox
  // id and the outcome, and deliberately carries no recipient address, no
  // subject and no body: enough to trace a delivery, not enough to leak who
  // was alerted about what.
  console.log(JSON.stringify({
    at: "resend_webhook",
    event: eventType,
    provider_message_id: providerMessageId,
    outbox_id: result.outbox_id ?? null,
    matched: result.matched ?? false,
    duplicate: result.duplicate ?? false,
    suppressed: result.suppressed ?? 0,
  }));

  return json({ received: true, ...result });
});
