import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const auth = req.headers.get("Authorization") ?? "";
  const url = Deno.env.get("SUPABASE_URL")!;

  // user-scoped client: resolves the caller's onboarding org via the state shim
  const userClient = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } } });
  const { data: state, error } = await userClient.rpc("muster_onboarding_state");
  if (error || !state?.website) return json({ ok: false, reason: "no_onboarding_website", error: error?.message }, 400);

  const site = state.website as { id: number; url: string; verification_token: string; verified_at: string | null };
  if (site.verified_at) return json({ ok: true, already_verified: true });

  let html = "";
  try {
    const res = await fetch(site.url, { headers: { "User-Agent": "MUSTER-Verify/1.0 (+https://muster.28footsystems.com)" }, redirect: "follow" });
    html = (await res.text()).slice(0, 200_000);
  } catch (e) {
    return json({ ok: false, reason: "fetch_failed", detail: String(e) }, 200);
  }

  const metaRe = new RegExp(`<meta[^>]+name=["']muster-verification["'][^>]+content=["']${site.verification_token}["']`, "i");
  const metaRe2 = new RegExp(`<meta[^>]+content=["']${site.verification_token}["'][^>]+name=["']muster-verification["']`, "i");
  if (!metaRe.test(html) && !metaRe2.test(html)) {
    return json({ ok: false, reason: "tag_not_found", expected: `<meta name="muster-verification" content="${site.verification_token}">` }, 200);
  }

  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { error: mErr } = await admin.rpc("muster_mark_website_verified", { p_website_id: site.id });
  if (mErr) return json({ ok: false, reason: "mark_failed", error: mErr.message }, 500);
  return json({ ok: true, verified: true });
});
