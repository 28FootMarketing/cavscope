import "jsr:@supabase/functions-js/edge-runtime.d.ts";

// Recovered into git on 2026-09-25 from the live deploy (version 6, pasted
// with no source file). One line differs from what was live: OFFER_DEADLINE_UTC
// carried the original 2026-09-26T15:59:00Z cutoff, superseded by migration
// 20260925062114 (muster_106), which moved the guard trigger and the Telegram
// payload to 2026-09-29T03:59:00Z. The export was the third copy of that date
// and nothing kept it in step, so its "Offer Deadline" column was wrong and its
// "Offer Status" column would have flipped to Expired two days early.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
// 9/28/2026 11:59 PM ET (EDT, UTC-4). Must match public.muster_beta_signup_guard().
const OFFER_DEADLINE_UTC = "2026-09-29T03:59:00Z";

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

function csvCell(v: unknown): string {
  const s = String(v ?? "");
  if (/[",\n]/.test(s)) return `"${s.replace(/"/g, '""')}"`;
  return s;
}

// Trailing weekday text defeats Sheets' auto number/date conversion on IMPORTDATA import
// (same reason the Time column, which already ends in "ET", never got mangled into a serial).
function easternDate(ts: string): string {
  const d = new Date(ts);
  const dateStr = d.toLocaleDateString("en-US", { timeZone: "America/New_York" });
  const weekday = d.toLocaleDateString("en-US", { timeZone: "America/New_York", weekday: "short" });
  return dateStr + " (" + weekday + ")";
}
function easternTime(ts: string): string {
  return new Date(ts).toLocaleTimeString("en-US", { timeZone: "America/New_York", hour: "2-digit", minute: "2-digit" }) + " ET";
}

Deno.serve(async (req: Request) => {
  if (req.method !== "GET") {
    return new Response("Method not allowed", { status: 405 });
  }

  const url = new URL(req.url);
  const provided = url.searchParams.get("key");
  const expected = await getSecret("muster_beta_export_key");
  if (!expected || provided !== expected) {
    return new Response("Unauthorized", { status: 401 });
  }

  const res = await fetch(
    `${SUPABASE_URL}/rest/v1/muster_beta_signups?select=full_name,company_name,industry,email,site_url,marketing_consent,status,created_at&order=created_at.desc`,
    {
      headers: {
        apikey: SERVICE_ROLE_KEY,
        Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
      },
    }
  );

  if (!res.ok) {
    return new Response("Failed to read signups", { status: 502 });
  }

  const rows: Array<Record<string, unknown>> = await res.json();
  const now = Date.now();
  const deadlineMs = new Date(OFFER_DEADLINE_UTC).getTime();
  const isExpired = now > deadlineMs;
  const deadlineLabel = easternDate(OFFER_DEADLINE_UTC) + " " + easternTime(OFFER_DEADLINE_UTC);

  const header = [
    "Date",
    "Time",
    "Name",
    "Company",
    "Industry",
    "Email",
    "Site URL",
    "Testimonial OK",
    "Offer Deadline",
    "Offer Status",
    "Status",
  ];

  const lines = [header.map(csvCell).join(",")];

  for (const r of rows) {
    const createdAt = String(r.created_at);
    lines.push(
      [
        easternDate(createdAt),
        easternTime(createdAt),
        r.full_name,
        r.company_name,
        r.industry,
        r.email,
        r.site_url,
        r.marketing_consent ? "Yes" : "No",
        deadlineLabel,
        isExpired ? "Expired" : "Active",
        r.status,
      ]
        .map(csvCell)
        .join(",")
    );
  }

  return new Response(lines.join("\n"), {
    status: 200,
    headers: {
      "Content-Type": "text/csv; charset=utf-8",
      "Cache-Control": "no-store",
    },
  });
});
