import { isFirstParty } from "./hosts.mjs";

// A request that failed in the browser is only a finding if it also fails over plain HTTP. A scan from a
// flaky or proxied network sees many failures that no visitor does; the request is fetched once more and,
// if it answers, it is marked transient and left out of SEC-021 (it stays in the evidence).
export async function confirmFailedRequests({ pages, siteHost, fetchStatus, max = 30 }) {
  let checked = 0;
  for (const p of pages) for (const r of p.requests ?? []) {
    if (!r.failed || r.aborted || !r.host || !isFirstParty(r.host, siteHost) || checked >= max) continue;
    checked++;
    const st = await fetchStatus(r.url);
    if (st != null && st < 400) { r.transient = true; r.confirmedStatus = st; }
  }
  return checked;
}
