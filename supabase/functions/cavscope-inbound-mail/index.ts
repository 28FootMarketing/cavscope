// Forwards mail sent to CavScope's support@ and security@ to a real inbox.
//
// Resend receives mail for mail.cavscope.28footsystems.com (and the retired
// mail.muster.partners) and posts an email.received event here. Each message
// addressed to a row in cavscope.mail_routes is forwarded to that row's
// forward_to, Reply-To the original sender, so answering from the owner's
// inbox answers the person who wrote in. Before this existed nothing read
// these addresses: a vulnerability report sent to security@ reached no one.
//
// Reachable without a JWT because the caller is Resend. The Svix signature is
// the only thing between this endpoint and anyone who can guess the URL, so an
// unverifiable request is refused before the body is parsed, and a missing
// signing secret fails closed. The secret is Vault's
// cavscope_resend_inbound_webhook_secret (CAVSCOPE_INBOUND_WEBHOOK_SECRET in
// the environment wins when set).
//
// The Resend account is shared with other brands and a webhook receives every
// domain's events, so anything not addressed to a CavScope route is answered
// 200 and dropped: nothing about another brand's mail is stored or read.

import { createClient } from "jsr:@supabase/supabase-js@2";
import { verifySvixSignature } from "../muster-resend-webhook/core.ts";
import { addressedTo, addressOf, buildForward, isOwnDomain, retryable, type Route, usableTargets } from "./core.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY") ?? "";

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

type Body = { text: string; html: string; attachments: number; fetched: boolean };

// email.received carries the envelope; the body comes from the Received Emails
// API. A sending-only key cannot read it -- the forward still goes out, saying
// where to find the message, rather than not going out at all.
async function receivedBody(emailId: string): Promise<Body> {
  try {
    const res = await fetch(`https://api.resend.com/emails/receiving/${encodeURIComponent(emailId)}`, {
      headers: { Authorization: `Bearer ${RESEND_API_KEY}` },
    });
    if (!res.ok) return { text: "", html: "", attachments: 0, fetched: false };
    const b = await res.json().catch(() => ({})) as Record<string, unknown>;
    return {
      text: typeof b.text === "string" ? b.text : "",
      html: typeof b.html === "string" ? b.html : "",
      attachments: Array.isArray(b.attachments) ? b.attachments.length : 0,
      fetched: true,
    };
  } catch {
    return { text: "", html: "", attachments: 0, fetched: false };
  }
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  const db = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });

  let secret = Deno.env.get("CAVSCOPE_INBOUND_WEBHOOK_SECRET") ?? "";
  if (!secret) {
    const { data, error } = await db.rpc("cavscope_engine_inbound_secret");
    if (error) console.error("cavscope-inbound-mail: secret lookup failed", error.message);
    secret = typeof data === "string" ? data : "";
  }
  if (!secret) return json({ error: "webhook verification is not configured" }, 503);

  const raw = await req.text();
  const verified = await verifySvixSignature(secret, {
    id: req.headers.get("svix-id") ?? req.headers.get("webhook-id"),
    timestamp: req.headers.get("svix-timestamp") ?? req.headers.get("webhook-timestamp"),
    signature: req.headers.get("svix-signature") ?? req.headers.get("webhook-signature"),
  }, raw);
  if (!verified.ok) return json({ error: "invalid signature", reason: verified.reason }, 401);

  let event: { type?: string; data?: Record<string, unknown> };
  try { event = JSON.parse(raw); } catch { return json({ error: "invalid JSON body" }, 400); }
  if (event.type !== "email.received") return json({ ignored: event.type ?? "no type" });

  const data = event.data ?? {};
  const to = addressedTo(data);
  if (!to.some(isOwnDomain)) return json({ ignored: "not a CavScope address" });

  const { data: rows, error: routeErr } = await db.rpc("cavscope_engine_mail_routes", { p_addresses: to });
  if (routeErr) return json({ error: routeErr.message }, 500);
  const routes = (Array.isArray(rows) ? rows : []) as Route[];
  if (!routes.length) return json({ ignored: "no route for this address" });

  const from = addressOf(data.from);
  // The relay's own mail never goes round again.
  if (!from || isOwnDomain(from)) return json({ ignored: "from a CavScope mailbox" });
  const emailId = typeof data.email_id === "string" ? data.email_id : "";
  if (!emailId) return json({ error: "no email_id on the event" }, 400);
  if (!RESEND_API_KEY) return json({ error: "no Resend key; not forwarded" }, 503);

  const body = await receivedBody(emailId);
  const results: Array<{ address: string; ok: boolean; skipped?: string; error?: string }> = [];
  let retry = false;

  for (const route of routes) {
    if (!usableTargets(route).length) { results.push({ address: route.address, ok: false, skipped: "no usable forward_to" }); continue; }
    const { data: claimed, error: claimErr } = await db.rpc("cavscope_engine_claim_mail_forward", { p_email_id: emailId, p_address: route.address });
    if (claimErr) { retry = true; results.push({ address: route.address, ok: false, error: claimErr.message }); continue; }
    if (!claimed) { results.push({ address: route.address, ok: true, skipped: "already forwarded" }); continue; }

    const payload = buildForward({
      route, from, subject: typeof data.subject === "string" ? data.subject : null,
      text: body.text, html: body.html, attachments: body.attachments, bodyFetched: body.fetched,
    });
    let status = 0, detail = "";
    try {
      const res = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${RESEND_API_KEY}`,
          "content-type": "application/json",
          // A redelivered webhook can never send a second copy.
          "Idempotency-Key": `cavscope-inbound-${emailId}-${route.address}`,
        },
        body: JSON.stringify(payload),
      });
      status = res.status;
      if (!res.ok) detail = (await res.text()).slice(0, 300);
    } catch (err) {
      detail = `network: ${String(err).slice(0, 200)}`;
    }
    const ok = status >= 200 && status < 300;
    await db.rpc("cavscope_engine_finish_mail_forward", { p_email_id: emailId, p_address: route.address, p_ok: ok, p_error: ok ? null : `${status} ${detail}` });
    if (!ok) {
      console.error("cavscope-inbound-mail: forward failed", route.address, status, detail);
      if (retryable(status)) retry = true;
    }
    results.push({ address: route.address, ok, ...(ok ? {} : { error: `${status}` }) });
  }

  // A 5xx makes Resend redeliver; the claim and the idempotency key make that safe.
  return json({ forwarded: results }, retry ? 502 : 200);
});
