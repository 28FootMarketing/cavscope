import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { buildEmail, validate, type Route } from "./core.ts";

// In-app support. A signed-in person posts { category, message, page_url, user_agent, viewport,
// organization_id, screenshot }. The request is filed through public.cavscope_submit_support_request
// under the caller's own JWT (which checks sign-in, the category list, org membership and the
// 10-an-hour limit), then emailed to the support route in cavscope.mail_routes, Reply-To the
// person, so answering from the inbox answers them.
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
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${RESEND_API_KEY}`, "content-type": "application/json", "Idempotency-Key": `cavscope-support-${id}` },
      body: JSON.stringify(buildEmail({ id, route, from: email, v })),
    });
    if (!res.ok) throw new Error(`resend ${res.status}`);
    await finish(true);
    return json({ ok: true, id, delivered: true });
  } catch (e) {
    console.error("cavscope-support-request: delivery failed", id, String(e).slice(0, 200));
    await finish(false, String(e));
    return json({ ok: true, id, delivered: false });
  }
});
