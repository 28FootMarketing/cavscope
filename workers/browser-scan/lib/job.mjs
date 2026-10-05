// One browser-scan job, host-independent: claim it, run it, hand the result back. The host (a Vercel
// function) supplies `rpc` and `run`; nothing here knows what Chromium is, so it is tested with fakes.
//
// The database is reached through public.cavscope_worker_* RPCs that check a shared secret (a Vault entry)
// themselves, and that only touch scans whose engine is 'browser' and that are still 'running'. The host
// holds that one secret and the public anon key; it holds no service-role key.

export function makeRpc({ url, anonKey, secret, fetchImpl = fetch }) {
  return async (name, args = {}) => {
    const res = await fetchImpl(`${url}/rest/v1/rpc/${name}`, {
      method: "POST",
      headers: { apikey: anonKey, authorization: `Bearer ${anonKey}`, "content-type": "application/json" },
      body: JSON.stringify({ p_secret: secret, ...args }),
    });
    const text = await res.text();
    if (!res.ok) throw new Error(`${name} ${res.status}: ${text.slice(0, 200)}`);
    return text ? JSON.parse(text) : null;
  };
}

export async function processScan({ rpc, job, run, log = () => {} }) {
  log(`[scan ${job.scan_id}] ${job.target_url}`);
  try {
    let previousKeys = new Set();
    try {
      const prev = await rpc("cavscope_worker_open_findings", { p_website_id: job.website_id });
      previousKeys = new Set((prev ?? []).map((r) => `${r.rule_id}|${r.location}`));
    } catch (e) { log(`[scan ${job.scan_id}] could not read previous findings: ${e.message}`); }

    const result = await run({
      targetUrl: job.target_url,
      options: { ...(job.options ?? {}), verified: job.verified === true, endpoint_hosts: job.endpoint_hosts ?? [] },
      previousKeys,
    });
    const ingested = await rpc("cavscope_worker_ingest", { p_scan_id: job.scan_id, p_scan: result.scan, p_evidence: result.evidence, p_findings: result.findings });
    log(`[scan ${job.scan_id}] done ${JSON.stringify(ingested)}`);
    return { ok: true, scan_id: job.scan_id, ingested };
  } catch (e) {
    log(`[scan ${job.scan_id}] failed: ${e?.message ?? e}`);
    // A scan the host cannot finish is failed with a short reason; it must not sit "running" until the
    // database's own 20-minute timeout.
    await rpc("cavscope_worker_fail", { p_scan_id: job.scan_id, p_error: `browser engine: ${String(e?.message ?? e).slice(0, 400)}` }).catch((e2) => log(`could not record failure: ${e2.message}`));
    return { ok: false, scan_id: job.scan_id, error: String(e?.message ?? e).slice(0, 200) };
  }
}

// Claim up to `limit` queued scans (or the one named) and process them in turn.
export async function dispatch({ rpc, scanId = null, limit = 1, run, log }) {
  const jobs = (await rpc("cavscope_worker_claim_browser", { p_scan_id: scanId, p_limit: limit })) ?? [];
  const results = [];
  for (const job of jobs) results.push(await processScan({ rpc, job, run, log }));
  return { claimed: jobs.length, results };
}
