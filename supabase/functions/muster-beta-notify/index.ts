import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const BOT_TOKEN = Deno.env.get("MUSTER_TELEGRAM_BOT_TOKEN")!;
const CORA_CHAT_ID = "1238597047";

async function getSecret(name: string): Promise<string> {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/muster_get_secret`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      apikey: SERVICE_ROLE_KEY,
      Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
    },
    body: JSON.stringify({ p_name: name }),
  });
  if (!res.ok) throw new Error(`secret lookup failed for ${name}: ${res.status}`);
  return await res.json();
}

function escapeForTelegram(s: string): string {
  return String(s ?? "").replace(/[<>&]/g, (c) => ({ "<": "&lt;", ">": "&gt;", "&": "&amp;" }[c]!));
}

function fmt(ts: string): string {
  try {
    return new Date(ts).toLocaleString("en-US", { timeZone: "America/New_York", dateStyle: "medium", timeStyle: "short" }) + " ET";
  } catch {
    return ts;
  }
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  const expected = await getSecret("muster_beta_notify_secret");
  const provided = req.headers.get("x-muster-signal");
  if (!expected || provided !== expected) {
    return new Response("Unauthorized", { status: 401 });
  }

  const payload = await req.json().catch(() => null);
  if (!payload) {
    return new Response("Bad request", { status: 400 });
  }

  const { full_name, company_name, industry, email, site_url, marketing_consent, created_at, offer_deadline } = payload;

  const lines = [
    "📡 <b>MUSTER — new beta signup</b>",
    "",
    `<b>Name:</b> ${escapeForTelegram(full_name)}`,
    `<b>Company:</b> ${escapeForTelegram(company_name)}`,
    `<b>Industry:</b> ${escapeForTelegram(industry)}`,
    `<b>Email:</b> ${escapeForTelegram(email)}`,
    `<b>Site:</b> ${escapeForTelegram(site_url)}`,
    `<b>Testimonial OK:</b> ${marketing_consent ? "Yes" : "No"}`,
    `<b>Submitted:</b> ${escapeForTelegram(fmt(created_at))}`,
    `⏳ <b>Offer closes:</b> ${escapeForTelegram(fmt(offer_deadline))} — fixed campaign deadline`,
  ];

  const tgRes = await fetch(`https://api.telegram.org/bot${BOT_TOKEN}/sendMessage`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      chat_id: CORA_CHAT_ID,
      text: lines.join("\n"),
      parse_mode: "HTML",
    }),
  });

  if (!tgRes.ok) {
    const detail = await tgRes.text();
    console.error("telegram send failed", tgRes.status, detail);
    return new Response("Telegram send failed", { status: 502 });
  }

  return new Response("ok", { status: 200 });
});
