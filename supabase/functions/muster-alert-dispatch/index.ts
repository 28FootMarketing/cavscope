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
        headers: { Authorization: `Bearer ${apiKey}`, "content-type": "application/json" },
        body: JSON.stringify({
          from: ALERT_FROM_ADDRESS,
          to: row.recipient_emails,
          subject: row.subject,
          text: row.body_text,
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
