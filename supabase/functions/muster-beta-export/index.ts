import "jsr:@supabase/functions-js/edge-runtime.d.ts";

// Recovered into git on 2026-09-25 from the live deploy (version 6, pasted
// with no source file). One line differs from what was live: OFFER_DEADLINE_UTC
// carried the original 2026-09-26T15:59:00Z cutoff, superseded by migration
// 20260925062114 (muster_106), which moved the guard trigger and the Telegram
// payload to 2026-09-29T03:59:00Z. The export was the third copy of that date
// and nothing kept it in step, so its "Offer Deadline" column was wrong and its
// "Offer Status" column would have flipped to Expired two days early.
//
// Scan columns added the same day, once migration 107 made every signup queue
// a sandbox scan: the read moved from the table to muster_engine_beta_export()
// so the scan's status, posture and open-finding counts ride along.

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

// What the reader needs to know about the scan, in one word. "not queued" is a
// row that predates migration 107 and was never backfilled, or one whose
// trigger raised before it could write scan_id; either way the Scan Error
// column says which.
function scanStatus(r: Record<string, unknown>): string {
  if (r.scan_error) return "error";
  if (!r.scan_id) return "not queued";
  return String(r.scan_status ?? "queued");
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

  // One engine RPC (migration 20260925071634, muster_108) rather than a table
  // read: the signup's scan lives in muster.scans, which PostgREST does not
  // expose, and the RPC joins the two. service_role is the only grantee.
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/muster_engine_beta_export`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      apikey: SERVICE_ROLE_KEY,
      Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
    },
    body: "{}",
  });

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
    // Scan columns are appended after the original eleven so a sheet formula
    // written against column letters A..K keeps meaning what it meant.
    "Scan ID",
    "Scan Status",
    "Scan Finished",
    "Posture Score",
    "Posture Band",
    "Critical",
    "High",
    "Medium",
    "Low",
    "Info",
    "Scan Error",
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
        r.scan_id,
        scanStatus(r),
        r.scan_finished_at ? easternDate(String(r.scan_finished_at)) + " " + easternTime(String(r.scan_finished_at)) : "",
        // Score and counts are blank, not zero, until the scan is complete: a
        // 0 in a sheet reads as a clean site, and an unfinished scan is not one.
        r.scan_status === "complete" ? r.posture_score : "",
        r.scan_status === "complete" ? r.posture_band : "",
        r.scan_status === "complete" ? r.open_critical : "",
        r.scan_status === "complete" ? r.open_high : "",
        r.scan_status === "complete" ? r.open_medium : "",
        r.scan_status === "complete" ? r.open_low : "",
        r.scan_status === "complete" ? r.open_info : "",
        r.scan_error,
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
