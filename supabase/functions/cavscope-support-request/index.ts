import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { buildEmail, validate, type Route, type Valid } from "./core.ts";
import { buildMessages, buildTriageEmail, extractTriage, TRIAGE_TOOL } from "./ai.ts";

// In-app support. A signed-in person posts { category, message, page_url, user_agent, viewport,
// organization_id, screenshot }. The request is filed through public.cavscope_submit_support_request
// under the caller's own JWT (which checks sign-in, the category list, org membership and the
// 10-an-hour limit), then emailed to the support route in cavscope.mail_routes, Reply-To the
// person, so answering from the inbox answers them.
//
// AI triage (flag support_ai, dark until an owner turns it on): after the request is on file and
// support has the original email, a model reads the request, the screenshot and a few account facts,
// and support gets a SECOND email: summary, what is on screen, likely cause, suggested fix and a
// DRAFT reply. It runs after the response has gone back (EdgeRuntime.waitUntil), so the customer
// waits no longer for it, and nothing the model writes is ever sent to the customer.
//
// The screenshot is attached to that email and stored nowhere else: no table, no storage object.
// If the email cannot be sent the request is still on file (status 'failed') and the person is
// told it was saved rather than that it was delivered.

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

const URL_ = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY") ?? "";
const SUPPORT_ADDRESS = "support@mail.cavscope.28footsystems.com";
const MAX_BODY_BYTES = 5_000_000;
// Same key lookup the embedding functions use. The model is a setting, not a constant.
const AI_KEY = Deno.env.get("MUSTER_OPENROUTER_API_KEY") ?? Deno.env.get("OPENROUTER_API_KEY") ?? "";
const AI_MODEL = Deno.env.get("CAVSCOPE_SUPPORT_AI_MODEL") ?? "anthropic/claude-sonnet-4.5";

// deno-lint-ignore no-explicit-any
declare const EdgeRuntime: any;

async function sendMail(payload: unknown, idempotencyKey: string) {
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${RESEND_API_KEY}`, "content-type": "application/json", "Idempotency-Key": idempotencyKey },
    body: JSON.stringify(payload),
  });
  if (!res.ok) throw new Error(`resend ${res.status}`);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const auth = req.headers.get("authorization") ?? "";
  if (!auth.toLowerCase().startsWith("bearer ")) return json({ error: "Sign in to contact support." }, 401);

  const len = Number(req.headers.get("content-length") ?? 0);
  if (len > MAX_BODY_BYTES) return json({ error: "That is too large to send." }, 413);
  let body: unknown;
  try { body = await req.json(); } catch { return json({ error: "Send JSON." }, 400); }

  const checked = validate(body);
  if (!checked.ok) return json({ error: checked.error }, 400);
  const v = checked.value;

  const sb = createClient(URL_, ANON, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
  const user = await sb.auth.getUser();
  const email = user.data.user?.email ?? "";
  if (user.error || !email) return json({ error: "Sign in again to contact support." }, 401);

  const filed = await sb.rpc("cavscope_submit_support_request", {
    p_category: v.category, p_message: v.message, p_page_url: v.pageUrl, p_user_agent: v.userAgent,
    p_viewport: v.viewport, p_organization_id: v.organizationId, p_has_screenshot: v.screenshot !== null,
  });
  if (filed.error) {
    const code = filed.error.code;
    if (code === "54000") return json({ error: filed.error.message }, 429);
    if (code === "42501") return json({ error: "You cannot send support messages from this workspace." }, 403);
    return json({ error: "Your message could not be saved. Try again in a moment." }, 502);
  }
  const id = Number(filed.data);

  const db = createClient(URL_, SERVICE, { auth: { persistSession: false } });
  const finish = (ok: boolean, error?: string) =>
    db.rpc("cavscope_engine_finish_support_request", { p_id: id, p_ok: ok, p_email: email, p_error: error ?? null });

  try {
    if (!RESEND_API_KEY) throw new Error("no Resend key");
    const routes = await db.rpc("cavscope_engine_mail_routes", { p_addresses: [SUPPORT_ADDRESS] });
    const route = (Array.isArray(routes.data) ? routes.data[0] : null) as Route | null;
    if (!route || !route.forward_to?.length) throw new Error("no support route");
    await sendMail(buildEmail({ id, route, from: email, v }), `cavscope-support-${id}`);
    await finish(true);
    EdgeRuntime.waitUntil(triage(db, id, route, v));
    return json({ ok: true, id, delivered: true });
  } catch (e) {
    console.error("cavscope-support-request: delivery failed", id, String(e).slice(0, 200));
    await finish(false, String(e));
    return json({ ok: true, id, delivered: false });
  }
});

// Never throws and never blocks the response. A failure is recorded on the request, not raised.
// deno-lint-ignore no-explicit-any
async function triage(db: any, id: number, route: Route, v: Valid) {
  const done = (status: string, result: unknown = null, error: string | null = null) =>
    db.rpc("cavscope_engine_finish_support_ai", { p_id: id, p_status: status, p_result: result, p_model: AI_MODEL, p_error: error });
  try {
    const on = await db.rpc("cavscope_engine_support_ai_enabled");
    if (on.error || on.data !== true) return; // dark: nothing leaves the building
    if (!AI_KEY) { await done("skipped", null, "no OpenRouter key in the function environment"); return; }
    await done("pending");
    const ctx = await db.rpc("cavscope_engine_support_context", { p_id: id });
    let shot: string | null = null;
    if (v.screenshot) {
      let bin = "";
      for (const byte of v.screenshot.bytes) bin += String.fromCharCode(byte);
      shot = `data:${v.screenshot.mime};base64,${btoa(bin)}`;
    }
    const res = await fetch("https://openrouter.ai/api/v1/chat/completions", {
      method: "POST",
      headers: { Authorization: `Bearer ${AI_KEY}`, "content-type": "application/json", "X-Title": "CavScope support triage" },
      body: JSON.stringify({
        model: AI_MODEL,
        max_tokens: 1500,
        messages: buildMessages({
          id, category: v.category, message: v.message, pageUrl: v.pageUrl, userAgent: v.userAgent,
          viewport: v.viewport, context: ctx.data ?? null, screenshotDataUrl: shot,
        }),
        tools: [TRIAGE_TOOL],
        tool_choice: { type: "function", function: { name: "record_triage" } },
      }),
      signal: AbortSignal.timeout(45_000),
    });
    if (!res.ok) throw new Error(`model ${res.status}`);
    const t = extractTriage(await res.json());
    if (!t) throw new Error("the model's answer did not match the schema");
    await done("done", t);
    await sendMail(buildTriageEmail({ id, route, category: v.category, t, model: AI_MODEL }), `cavscope-support-ai-${id}`);
  } catch (e) {
    console.error("cavscope-support-request: triage failed", id, String(e).slice(0, 200));
    await done("failed", null, String(e).slice(0, 280));
  }
}
