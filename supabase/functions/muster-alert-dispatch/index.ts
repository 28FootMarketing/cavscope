import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

// PRD-001 (.planning/autonomy/prds/PRD-001-critical-finding-alerts.md):
// dispatches queued muster.notification_outbox rows (populated by
// muster.autotriage() when it opens a critical/high risk) via Resend.
//
// Invocation (same shared-secret pattern as muster-scan):
//   Authorization: Bearer <anon key>
//   x-muster-secret: <vault muster_cron_secret>
//   body: {} (cron-only; no per-call parameters needed)
//
// Claims up to 20 pending rows via public.muster_engine_claim_alerts (a
// SELECT ... FOR UPDATE SKIP LOCKED claim, same concurrency-safety pattern
// as the scan engine's own claim function), sends each through Resend, then
// resolves it via public.muster_engine_resolve_alert. That RPC owns the
// retry policy, not this function: a failed send is requeued to 'pending'
// (picked up on the next 5-minute cron tick -- that interval is the backoff,
// not a fixed delay computed here) for up to 5 attempts total, then
// dead-lettered to a terminal 'failed' status excluded from future claims.
//
// RESEND_API_KEY must be set as an Edge Function secret for this project
// (Supabase dashboard -> Edge Functions -> Secrets). Until it is, every
// claimed row will resolve as failed with a clear "RESEND_API_KEY is not
// set" error recorded on the row -- rows queue harmlessly, nothing is lost,
// nothing silently disappears. See BLOCKERS-AND-DECISIONS.md B-2.
//
// This is the APPLICATION email path. Auth email (magic link, password reset,
// invite) does NOT come through here -- Supabase Auth sends those itself, and
// only reaches Resend because Resend is configured as its SMTP relay. See
// docs/EMAIL.md before assuming a change here affects sign-in mail.

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

const RESEND_API_BASE = "https://api.resend.com";

// MUSTER sends from its own domain now that muster.partners is the product's
// home. mail.muster.partners is verified in Resend with sending enabled
// (confirmed 2026-09-07). The previous mail.28footsystems.com is also still
// verified, so nothing breaks in either direction -- but alerts about a MUSTER
// tenant should not arrive from the parent company's domain.
//
// Overridable by env so this same code is correct on both Supabase projects
// during the move to hjowfnzpomzxazmzywxw, and so a domain change later is a
// secret edit rather than a redeploy. Resend rejects a from-address on an
// unverified domain outright, so a typo here fails loudly at send time and the
// row is recorded as failed with the API's message -- it does not vanish.
const ALERT_FROM_ADDRESS = Deno.env.get("MUSTER_ALERT_FROM")
  ?? "MUSTER Alerts <alerts@mail.muster.partners>";

// Where "Open the risk register" points. Overridable for the same reason as
// the from-address: this code runs on two Supabase projects during the move,
// and the workspace host has changed once already.
const APP_URL = Deno.env.get("MUSTER_APP_URL") ?? "https://app.muster.partners/app";

// Opt-in, with no default on purpose. Receiving is disabled on
// mail.muster.partners, so a reply to the sending address goes nowhere -- and
// inventing a support@ that may not exist would be worse than omitting the
// header. Set MUSTER_ALERT_REPLY_TO to a real monitored inbox and replies
// start working; leave it unset and the email simply does not invite one.
const ALERT_REPLY_TO = Deno.env.get("MUSTER_ALERT_REPLY_TO") ?? "";

const SEVERITY_COLOR: Record<string, string> = {
  critical: "#f43f5e",
  high: "#fbbf24",
};

function esc(v: string): string {
  return v
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

// Renders the same body_text the plain-text part carries, as branded HTML.
// The text part is not dropped -- both are sent, so a text-only client and a
// spam filter that scores multipart/alternative both get what they expect.
// Blank-line-separated blocks become paragraphs; nothing else is interpreted,
// so scanner-supplied strings in a finding title cannot inject markup.
function alertHtml(row: OutboxRow): string {
  const accent = SEVERITY_COLOR[row.severity] ?? "#36e2c9";
  const paragraphs = row.body_text
    .split(/\n{2,}/)
    .map((block) => block.trim())
    .filter((block) => block.length > 0)
    .map((block) =>
      `            <p style="margin-top:0; margin-bottom:16px; font-family:Arial, Helvetica, sans-serif; font-size:15px; line-height:24px; color:#3a4a63;">${
        esc(block).replace(/\n/g, "<br>")
      }</p>`
    )
    .join("\n");

  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta http-equiv="X-UA-Compatible" content="IE=edge">
<title>${esc(row.subject)}</title>
</head>
<body style="margin:0; padding:0; background-color:#f4f6fa;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" bgcolor="#f4f6fa" style="background-color:#f4f6fa;">
  <tr>
    <td align="center" style="padding-top:32px; padding-bottom:32px; padding-left:12px; padding-right:12px;">
      <table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0" style="width:600px; max-width:600px;">

        <tr>
          <td bgcolor="#060a16" align="left" style="background-color:#060a16; border-top-left-radius:10px; border-top-right-radius:10px; padding-top:22px; padding-bottom:22px; padding-left:28px; padding-right:28px;">
            <table role="presentation" cellpadding="0" cellspacing="0" border="0">
              <tr>
                <td style="padding-right:12px;" valign="middle">
                  <img src="https://muster.partners/assets/muster-emblem.png" width="34" height="34" border="0" alt="MUSTER" style="display:block; width:34px; height:34px;">
                </td>
                <td valign="middle">
                  <span style="font-family:Georgia, 'Times New Roman', serif; font-size:19px; line-height:24px; font-weight:700; letter-spacing:2px; color:#f1f6ff;">MUSTER</span>
                </td>
              </tr>
            </table>
          </td>
        </tr>

        <tr>
          <td bgcolor="${accent}" style="background-color:${accent}; font-size:0; line-height:0; height:4px;">&nbsp;</td>
        </tr>

        <tr>
          <td bgcolor="#ffffff" align="left" style="background-color:#ffffff; padding-top:30px; padding-bottom:30px; padding-left:28px; padding-right:28px;">

            <p style="margin-top:0; margin-bottom:14px; font-family:Arial, Helvetica, sans-serif; font-size:11px; line-height:16px; font-weight:700; letter-spacing:1.5px; text-transform:uppercase; color:${accent};">${esc(row.severity)} &middot; new risk opened</p>

            <p style="margin-top:0; margin-bottom:20px; font-family:Arial, Helvetica, sans-serif; font-size:20px; line-height:28px; font-weight:700; color:#0c1527;">${esc(row.subject)}</p>

${paragraphs}

            <table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin-top:10px; margin-bottom:6px;">
              <tr>
                <td bgcolor="#36e2c9" align="center" style="background-color:#36e2c9; border-radius:8px;">
                  <a href="${esc(APP_URL)}" style="display:block; font-family:Arial, Helvetica, sans-serif; font-size:15px; line-height:20px; font-weight:700; color:#06201d; text-decoration:none; padding-top:14px; padding-bottom:14px; padding-left:32px; padding-right:32px;">Open the risk register</a>
                </td>
              </tr>
            </table>

          </td>
        </tr>

        <tr>
          <td bgcolor="#ffffff" align="left" style="background-color:#ffffff; border-bottom-left-radius:10px; border-bottom-right-radius:10px; border-top-width:1px; border-top-style:solid; border-top-color:#e3e8f0; padding-top:20px; padding-bottom:24px; padding-left:28px; padding-right:28px;">
            <p style="margin-top:0; margin-bottom:6px; font-family:Arial, Helvetica, sans-serif; font-size:12px; line-height:18px; color:#5d708e;">
              You are receiving this because you are listed as an alert recipient for your MUSTER organization. Alert recipients are managed in your workspace settings.
            </p>
            <p style="margin-top:0; margin-bottom:0; font-family:Arial, Helvetica, sans-serif; font-size:12px; line-height:18px; color:#8e9fb8;">
              MUSTER is website assurance by 28 Foot Systems, After Today, LLC &middot; Hanover, PA
            </p>
          </td>
        </tr>

      </table>
    </td>
  </tr>
</table>
</body>
</html>`;
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

type OutboxRow = {
  id: number;
  organization_id: number;
  category: string;
  entity_type: string;
  entity_id: number;
  severity: string;
  subject: string;
  body_text: string;
  recipient_emails: string[];
  attempts: number;
};

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const { data: secret } = await db.rpc("muster_engine_secret");
  const provided = req.headers.get("x-muster-secret") ?? "";
  if (!secret || provided !== secret) return json({ error: "unauthorized" }, 401);

  const apiKey = Deno.env.get("RESEND_API_KEY");

  const { data: claimed, error: claimErr } = await db.rpc("muster_engine_claim_alerts", { p_limit: 20 });
  if (claimErr) return json({ error: `claim failed: ${claimErr.message}` }, 500);

  const rows = (claimed ?? []) as OutboxRow[];
  let sent = 0;
  let failed = 0;

  for (const row of rows) {
    if (!apiKey) {
      await db.rpc("muster_engine_resolve_alert", { p_id: row.id, p_status: "failed", p_error: "RESEND_API_KEY is not set" });
      failed++;
      continue;
    }
    try {
      const res = await fetch(`${RESEND_API_BASE}/emails`, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${apiKey}`,
          "content-type": "application/json",
          // True send-once key, honoured by Resend. A row is claimed once, but
          // a network timeout after Resend already accepted the send would
          // otherwise re-send on the next tick. The outbox id is stable across
          // those retries, so the duplicate is dropped server-side.
          "Idempotency-Key": `muster-outbox-${row.id}`,
        },
        body: JSON.stringify({
          from: ALERT_FROM_ADDRESS,
          ...(ALERT_REPLY_TO ? { reply_to: ALERT_REPLY_TO } : {}),
          to: row.recipient_emails,
          subject: row.subject,
          text: row.body_text,
          html: alertHtml(row),
          // Keeps Gmail from collapsing separate alerts into one thread.
          // Alert subjects are formulaic by design, which is exactly the
          // shape Gmail groups -- and a critical risk hidden inside a
          // collapsed thread is a missed alert.
          headers: { "X-Entity-Ref-ID": `muster-outbox-${row.id}` },
        }),
      });
      if (res.ok) {
        await db.rpc("muster_engine_resolve_alert", { p_id: row.id, p_status: "sent" });
        sent++;
      } else {
        const errBody = await res.text().catch(() => res.statusText);
        await db.rpc("muster_engine_resolve_alert", { p_id: row.id, p_status: "failed", p_error: `Resend ${res.status}: ${errBody.slice(0, 500)}` });
        failed++;
      }
    } catch (e) {
      await db.rpc("muster_engine_resolve_alert", { p_id: row.id, p_status: "failed", p_error: String(e).slice(0, 500) });
      failed++;
    }
  }

  return json({ claimed: rows.length, sent, failed });
});
