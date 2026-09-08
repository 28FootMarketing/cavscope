// Pure half of the Resend webhook handler: signature verification and event
// mapping. No Deno globals, no database, no fetch, so tests/email exercises
// this exact code rather than a copy of it (same split as muster-agent's
// narrative.ts).

/**
 * Resend signs webhooks with Svix. Verified against 28FS's own production
 * handler (brd-recruiting-email-webhook), which has been receiving live Resend
 * deliveries since 2026-07:
 *
 *   headers        svix-id, svix-timestamp, svix-signature
 *   signed payload `${svix-id}.${svix-timestamp}.${raw body}`
 *   secret         "whsec_" prefix stripped, remainder base64-decoded
 *   algorithm      HMAC-SHA256, signature compared base64-encoded
 *   header format  "v1,<sig> v1,<sig> ..." (space separated; a rotation
 *                  window can carry more than one, and any match is valid)
 *
 * The raw body must be the exact bytes received. Re-serializing the parsed
 * JSON changes key order and whitespace and the signature will never match.
 */

export const SIGNATURE_TOLERANCE_SECONDS = 5 * 60;

export type SvixHeaders = {
  id: string | null;
  timestamp: string | null;
  signature: string | null;
};

export type VerifyFailure =
  | "missing_headers"
  | "bad_timestamp"
  | "stale_timestamp"
  | "bad_secret"
  | "signature_mismatch";

export type VerifyResult = { ok: true } | { ok: false; reason: VerifyFailure };

function timingSafeEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

function base64Decode(s: string): Uint8Array {
  return Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
}

/** Tolerates copy-paste artifacts (surrounding quotes, whitespace) around the stored secret. */
export function normalizeSecret(raw: string): string {
  const trimmed = raw.trim().replace(/^["']|["']$/g, "");
  return trimmed.startsWith("whsec_") ? trimmed.slice(6) : trimmed;
}

export async function verifySvixSignature(
  secret: string,
  headers: SvixHeaders,
  rawBody: string,
  nowSeconds: number = Math.floor(Date.now() / 1000),
): Promise<VerifyResult> {
  const { id, timestamp, signature } = headers;
  if (!id || !timestamp || !signature) return { ok: false, reason: "missing_headers" };

  const ts = Number.parseInt(timestamp, 10);
  if (!Number.isFinite(ts)) return { ok: false, reason: "bad_timestamp" };
  // Replay window. Without it a captured delivery stays valid forever.
  if (Math.abs(nowSeconds - ts) > SIGNATURE_TOLERANCE_SECONDS) {
    return { ok: false, reason: "stale_timestamp" };
  }

  let secretBytes: Uint8Array;
  try {
    secretBytes = base64Decode(normalizeSecret(secret));
  } catch {
    return { ok: false, reason: "bad_secret" };
  }
  if (secretBytes.length === 0) return { ok: false, reason: "bad_secret" };

  const key = await crypto.subtle.importKey("raw", secretBytes, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signed = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${id}.${timestamp}.${rawBody}`));
  const expected = new Uint8Array(signed);

  for (const part of signature.split(" ")) {
    const [version, sig] = part.split(",");
    if (version !== "v1" || !sig) continue;
    try {
      if (timingSafeEqual(expected, base64Decode(sig))) return { ok: true };
    } catch {
      // malformed base64 in one candidate; try the next
    }
  }
  return { ok: false, reason: "signature_mismatch" };
}

/** Only for tests and local verification. Production never signs, it verifies. */
export async function signSvixPayload(
  secret: string,
  id: string,
  timestamp: string,
  rawBody: string,
): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    base64Decode(normalizeSecret(secret)),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signed = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${id}.${timestamp}.${rawBody}`));
  return `v1,${btoa(String.fromCharCode(...new Uint8Array(signed)))}`;
}

// Event types muster.email_events accepts. Anything else Resend sends
// (contact.*, domain.*, email.received, email.scheduled) is not an error and
// is acknowledged unrecorded.
export type MusterEventType =
  | "sent" | "delivered" | "delivery_delayed"
  | "bounced" | "complained" | "failed"
  | "opened" | "clicked";

const EVENT_MAP: Record<string, MusterEventType> = {
  "email.sent": "sent",
  "email.delivered": "delivered",
  "email.delivery_delayed": "delivery_delayed",
  "email.bounced": "bounced",
  "email.complained": "complained",
  "email.failed": "failed",
  "email.opened": "opened",
  "email.clicked": "clicked",
};

export function mapResendEventType(resendType: string): MusterEventType | null {
  return EVENT_MAP[resendType] ?? null;
}

export type ResendEvent = {
  type?: string;
  created_at?: string;
  data?: {
    email_id?: string;
    to?: string[] | string;
    bounce?: { type?: string; subType?: string; message?: string };
  };
};

export type ParsedEvent = {
  eventType: MusterEventType;
  providerMessageId: string;
  occurredAt: string;
  recipients: string[];
  /** Kept small on purpose: this lands in a jsonb column, so no bodies and no headers. */
  detail: Record<string, unknown>;
};

export type ParseFailure = "unparseable" | "unmapped_type" | "missing_email_id";

export function parseResendEvent(rawBody: string): { ok: true; event: ParsedEvent } | { ok: false; reason: ParseFailure } {
  let event: ResendEvent;
  try {
    event = JSON.parse(rawBody);
  } catch {
    return { ok: false, reason: "unparseable" };
  }

  const eventType = mapResendEventType(event.type ?? "");
  if (!eventType) return { ok: false, reason: "unmapped_type" };

  const providerMessageId = event.data?.email_id;
  if (!providerMessageId) return { ok: false, reason: "missing_email_id" };

  const rawTo = event.data?.to;
  const recipients = (Array.isArray(rawTo) ? rawTo : rawTo ? [rawTo] : [])
    .map((a) => String(a).trim())
    .filter((a) => a.length > 0);

  const occurredAt = event.created_at && !Number.isNaN(Date.parse(event.created_at))
    ? new Date(event.created_at).toISOString()
    : new Date().toISOString();

  // Bounce classification only. A transient bounce (a full mailbox, a greylist)
  // is not a reason to retire an address; only the recording RPC decides what
  // to do with this, but it cannot decide without the type.
  const detail: Record<string, unknown> = {};
  if (event.data?.bounce?.type) detail.bounce_type = event.data.bounce.type;
  if (event.data?.bounce?.subType) detail.bounce_subtype = event.data.bounce.subType;

  return { ok: true, event: { eventType, providerMessageId, occurredAt, recipients, detail } };
}

/**
 * Whether a bounce is permanent. Resend reports "Transient" for soft bounces.
 * Unknown or absent classification is treated as permanent: a bounce we cannot
 * classify is safer suppressed than retried against a shared sending domain.
 */
export function isPermanentBounce(detail: Record<string, unknown>): boolean {
  const t = String(detail.bounce_type ?? "").toLowerCase();
  return t !== "transient";
}
