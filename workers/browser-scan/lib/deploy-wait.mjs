// OPS-001: after a change, wait until the live site shows it before scanning, so findings describe the
// deployed state and not a CDN's stale copy. Generic on purpose: a content marker in the body, or a header
// value, polled every 5 s for up to 3 minutes. No hosting integration is needed, only the URL.

export const WAIT_MAX_MS = 180_000;
export const WAIT_INTERVAL_MS = 5_000;

export async function waitForDeploy({ url, marker, header, headerValue, fetchImpl = fetch, now = Date.now, sleep = (ms) => new Promise((r) => setTimeout(r, ms)), maxMs = WAIT_MAX_MS, intervalMs = WAIT_INTERVAL_MS }) {
  if (!marker && !header) return { ok: true, waited: false, reason: "nothing to wait for" };
  const t0 = now();
  let attempts = 0, last = "no response";
  for (;;) {
    attempts++;
    try {
      const u = new URL(url); u.searchParams.set("cavscope_wait", String(attempts)); // bypass an edge cache that keys on the URL
      const res = await fetchImpl(u.toString(), { headers: { "cache-control": "no-cache" }, redirect: "follow" });
      if (header) {
        const v = res.headers.get(header);
        last = `header ${header}: ${v ?? "absent"}`;
        if (v != null && (headerValue == null || v.includes(headerValue))) return { ok: true, waited: true, attempts, ms: now() - t0 };
      } else {
        const text = await res.text();
        last = `HTTP ${res.status}, marker ${text.includes(marker) ? "present" : "absent"}`;
        if (res.ok && text.includes(marker)) return { ok: true, waited: true, attempts, ms: now() - t0 };
      }
    } catch (e) { last = String(e?.message ?? e).slice(0, 100); }
    if (now() - t0 + intervalMs > maxMs) return { ok: false, waited: true, attempts, ms: now() - t0, reason: `the deploy did not appear within ${Math.round(maxMs / 1000)} s (last: ${last})` };
    await sleep(intervalMs);
  }
}
