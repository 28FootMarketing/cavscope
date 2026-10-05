// Long-running worker: claims queued browser scans from Postgres, runs them, ingests the result.
// Run on a host that can run Chromium (see Dockerfile). Edge functions cannot.
//
//   SUPABASE_URL=https://hjowfnzpomzxazmzywxw.supabase.co
//   SUPABASE_SERVICE_ROLE_KEY=...            (service role: the engine RPCs are revoked from everyone else)
//   POLL_SECONDS=20                          (optional)
//
// A scan the worker cannot finish is failed through cavscope_engine_fail with a short reason, so
// nothing sits "running" until the 20-minute database timeout unless the worker itself died.

import { runBrowserScan } from "./lib/engine.mjs";

const URL_ = process.env.SUPABASE_URL;
const KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const POLL_MS = Math.max(5, Number(process.env.POLL_SECONDS ?? 20)) * 1000;

const rpc = async (name, args) => {
  const res = await fetch(`${URL_}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: { apikey: KEY, authorization: `Bearer ${KEY}`, "content-type": "application/json" },
    body: JSON.stringify(args ?? {}),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${name} ${res.status}: ${text.slice(0, 300)}`);
  return text ? JSON.parse(text) : null;
};

async function handle(job) {
  console.log(`[scan ${job.scan_id}] ${job.target_url} options=${JSON.stringify(job.options)}`);
  try {
    let previousKeys = new Set();
    try {
      const prev = await rpc("cavscope_engine_open_browser_findings", { p_website_id: job.website_id });
      previousKeys = new Set((prev ?? []).map((r) => `${r.rule_id}|${r.location}`));
    } catch (e) { console.warn(`[scan ${job.scan_id}] could not read previous findings: ${e.message}`); }

    const result = await runBrowserScan({ targetUrl: job.target_url, options: { ...(job.options ?? {}), verified: job.verified === true, endpoint_hosts: job.endpoint_hosts ?? [] }, previousKeys });
    const ingested = await rpc("cavscope_engine_ingest", { p_scan_id: job.scan_id, p_scan: result.scan, p_evidence: result.evidence, p_findings: result.findings });
    console.log(`[scan ${job.scan_id}] done`, JSON.stringify(ingested));
  } catch (e) {
    console.error(`[scan ${job.scan_id}] failed:`, e);
    await rpc("cavscope_engine_fail", { p_scan_id: job.scan_id, p_error: `browser engine: ${String(e.message ?? e).slice(0, 400)}` }).catch((e2) => console.error("could not record failure:", e2.message));
  }
}

async function main() {
  if (!URL_ || !KEY) { console.error("SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required"); process.exit(1); }
  console.log("browser-scan worker up; polling every", POLL_MS / 1000, "s");
  let stop = false;
  for (const sig of ["SIGTERM", "SIGINT"]) process.on(sig, () => { stop = true; });
  while (!stop) {
    try {
      const jobs = await rpc("cavscope_engine_claim_browser", { p_limit: 1 });
      if (jobs?.length) { for (const j of jobs) await handle(j); continue; }
    } catch (e) { console.error("claim failed:", e.message); }
    await new Promise((r) => setTimeout(r, POLL_MS));
  }
}
main();
