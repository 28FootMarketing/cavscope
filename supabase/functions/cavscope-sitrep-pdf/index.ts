import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { renderPdf } from "./pdf.ts";

// SITREP as a PDF. A signed-in caller posts { sitrep_id }; the function renders that report's own
// markdown (see pdf.ts for why) and returns the file.
//
// Who may call it is decided in Postgres, under the caller's own JWT:
// public.cavscope_pdf_export_allowed(sitrep_id) -- a member of the report's organization or a
// super admin, and the pdf_export flag on for that organization. The flag's kill switch stops
// super admins too. The report itself is then read through public.cavscope_sitrep, which checks
// membership again, so a guessed id returns nothing.
//
// Nothing is stored. The PDF is built in memory and returned; there is no table, no storage object
// and no log line carrying report content.

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Expose-Headers": "content-disposition",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

const URL_ = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const MAX_MARKDOWN_BYTES = 2_000_000;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const auth = req.headers.get("authorization") ?? "";
  if (!auth.toLowerCase().startsWith("bearer ")) return json({ error: "sign in first" }, 401);

  let body: { sitrep_id?: unknown };
  try { body = await req.json(); } catch { return json({ error: "send JSON: { \"sitrep_id\": 123 }" }, 400); }
  const id = Number(body.sitrep_id);
  if (!Number.isSafeInteger(id) || id <= 0) return json({ error: "sitrep_id must be a positive whole number" }, 400);

  const sb = createClient(URL_, ANON, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });

  const allowed = await sb.rpc("cavscope_pdf_export_allowed", { p_sitrep_id: id });
  if (allowed.error) return json({ error: "could not check access" }, 502);
  if (allowed.data !== true) return json({ error: "PDF export is not enabled for this report" }, 403);

  const rep = await sb.rpc("cavscope_sitrep", { p_sitrep_id: id });
  if (rep.error) return json({ error: "report not found" }, 404);
  const md: unknown = rep.data?.content_md;
  if (typeof md !== "string" || !md.trim()) return json({ error: "this report has no document to export" }, 409);
  if (new TextEncoder().encode(md).byteLength > MAX_MARKDOWN_BYTES) return json({ error: "report is too large to export" }, 413);

  const title = String(rep.data?.headline ?? `SITREP ${id}`);
  const bytes = await renderPdf(md, { title, generatedAt: rep.data?.generated_at ? new Date(rep.data.generated_at) : new Date() });
  return new Response(bytes, {
    status: 200,
    headers: { ...cors, "Content-Type": "application/pdf", "Content-Disposition": `attachment; filename="cavscope-sitrep-${id}.pdf"`, "Cache-Control": "no-store" },
  });
});
