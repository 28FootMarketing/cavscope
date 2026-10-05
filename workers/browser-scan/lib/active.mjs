// Group C: the tests that SEND data to the target (FORM-010, FORM-011). Nothing in this file runs unless
// the scan's options carry a stored authorization, which the database decides (see
// public.cavscope_request_browser_scan) and the engine re-checks (`activeTestsPermitted`).
//
// Every value sent is an obvious marker: name "CAVSCOPE TEST (delete me)", email at example.com.
// `buildMatrix` and `evaluateMatrix` are pure; `runMatrix` takes a fetch so a test can pass a fake.

import { registrableDomain } from "./hosts.mjs";

export const MARKER_NAME = "CAVSCOPE TEST (delete me)";
export const MARKER_EMAIL = "cavscope-test@example.com";
export const MARKER_PHONE = "5555550100";
export const DISALLOWED_ORIGIN = "https://cavscope-disallowed-origin.invalid";
export const MIN_FILL_MS = 3200;

// Both must hold: the database said yes AND the endpoint is on the site or on a host the authorization
// names. A form that posts to someone else's service is not covered by the site owner's say-so.
export function activeTestsPermitted({ options, verified, siteHost, endpointUrl }) {
  if (!options || options.active_tests !== true || typeof options.authorization_id !== "number") return { ok: false, reason: "no stored authorization on this scan" };
  if (!verified) return { ok: false, reason: "the site's ownership is not verified" };
  let host;
  try { host = new URL(endpointUrl).hostname; } catch { return { ok: false, reason: "the form endpoint is not a valid URL" }; }
  if (!/^https:/i.test(endpointUrl)) return { ok: false, reason: "the form endpoint is not HTTPS" };
  const allowed = new Set([registrableDomain(siteHost), ...(options.endpoint_hosts ?? []).map((h) => h.toLowerCase())]);
  if (!allowed.has(registrableDomain(host)) && !allowed.has(host.toLowerCase()))
    return { ok: false, reason: `the form posts to ${host}, which is not on the site's domain and is not listed in the authorization` };
  return { ok: true };
}

function parseBody(template) {
  const ct = (template.contentType ?? "").toLowerCase();
  const raw = template.body ?? "";
  if (ct.includes("application/json")) { try { const o = JSON.parse(raw); return o && typeof o === "object" && !Array.isArray(o) ? { kind: "json", obj: o } : null; } catch { return null; } }
  if (ct.includes("application/x-www-form-urlencoded")) return { kind: "form", obj: Object.fromEntries(new URLSearchParams(raw)) };
  return null; // multipart and anything else: not reshaped
}
const encode = (kind, obj) => (kind === "json" ? JSON.stringify(obj) : new URLSearchParams(Object.entries(obj).map(([k, v]) => [k, String(v)])).toString());
const keyMatching = (obj, re) => Object.keys(obj).find((k) => re.test(k));

// `hiddenFields`: names of text fields a person cannot see (skipped by the collector when filling), which
// is what a honeypot is. `origin`: the site's own origin, used for the Origin header.
export function buildMatrix({ template, hiddenFields = [], origin }) {
  const parsed = parseBody(template);
  const base = { method: template.method || "POST", url: template.url };
  const hdr = (extra = {}) => ({ "content-type": template.contentType ?? "application/json", origin, ...extra });
  const na = (id, label, why) => ({ id, label, notApplicable: why });
  if (!parsed) return [1, 2, 3, 4, 5, 6, 7].map((n) => na(n, "", "the form's request body is not JSON or form-encoded, so it cannot be reshaped safely"));
  const { kind, obj } = parsed;
  const mk = (id, label, expect, mutate, headers) => { const o = structuredClone(obj); mutate?.(o); return { id, label, expect, request: { ...base, headers: hdr(headers), body: encode(kind, o) } }; };

  const optionKey = keyMatching(obj, /service|interest|type|option|topic|reason|category|sport|program|subject/i);
  const consentKey = keyMatching(obj, /sms|consent|opt.?in|text/i);
  const phoneKey = keyMatching(obj, /phone|mobile|\btel\b|cell/i);
  const timingKey = keyMatching(obj, /time|^ts$|started|elapsed|rendered|loaded_at/i);
  const honeypot = hiddenFields[0];

  const tooFastValue = (v) => (typeof v === "number" ? (v > 1e12 ? Date.now() : v > 1e9 ? Math.floor(Date.now() / 1000) : 0) : String(v).length > 10 ? new Date().toISOString() : "0");
  return [
    mk(1, "Valid payload", "2xx"),
    optionKey ? mk(2, `Unknown option (${optionKey})`, "400", (o) => { o[optionKey] = "cavscope-invalid-option"; }) : na(2, "Unknown option", "no option-like field in the form's request"),
    consentKey && phoneKey ? mk(3, "SMS consent with no phone", "400", (o) => { o[consentKey] = typeof o[consentKey] === "string" ? "on" : true; o[phoneKey] = ""; }) : na(3, "SMS consent with no phone", "no phone and consent fields in the form's request"),
    honeypot ? mk(4, `Honeypot filled (${honeypot})`, "silent-2xx", (o) => { o[honeypot] = "cavscope-bot"; }) : na(4, "Honeypot filled", "no hidden field found to act as a honeypot"),
    timingKey ? mk(5, `Too-fast submission (${timingKey})`, "silent-2xx", (o) => { o[timingKey] = tooFastValue(o[timingKey]); }) : na(5, "Too-fast submission", "no timing field in the form's request"),
    mk(6, "Request from a disallowed Origin", "403", null, { origin: DISALLOWED_ORIGIN }),
    { id: 7, label: "CORS preflight", expect: "preflight", request: { method: "OPTIONS", url: template.url, headers: { origin, "access-control-request-method": base.method, "access-control-request-headers": "content-type" }, body: undefined } },
  ];
}

const meets = (expect, status) => ({
  "2xx": status >= 200 && status < 300,
  "400": status === 400 || status === 422,
  "403": status === 401 || status === 403,
  "silent-2xx": status >= 200 && status < 300,
  preflight: status >= 200 && status < 300,
}[expect]);

export async function runMatrix({ cases, fetchImpl }) {
  const results = [];
  for (const c of cases) {
    if (c.notApplicable) { results.push({ id: c.id, label: c.label, notApplicable: c.notApplicable }); continue; }
    try {
      const res = await fetchImpl(c.request.url, { method: c.request.method, headers: c.request.headers, body: c.request.body });
      results.push({
        id: c.id, label: c.label, expect: c.expect, status: res.status,
        acao: res.headers.get("access-control-allow-origin"), acac: res.headers.get("access-control-allow-credentials"),
        sentOrigin: c.request.headers.origin,
      });
    } catch (e) { results.push({ id: c.id, label: c.label, expect: c.expect, status: null, error: String(e?.message ?? e).slice(0, 120) }); }
  }
  return results;
}

export function evaluateMatrix({ results, origin, evidenceKey = "active_matrix" }) {
  const dev = [];
  const lines = [];
  for (const r of results) {
    if (r.notApplicable) { lines.push(`${r.id}. ${r.label || "case"}: not applicable (${r.notApplicable})`); continue; }
    if (r.status == null) { dev.push(`${r.id}. ${r.label}: no response (${r.error})`); lines.push(`${r.id}. ${r.label}: no response`); continue; }
    const ok = meets(r.expect, r.status);
    lines.push(`${r.id}. ${r.label}: ${r.status}${r.acao ? ` (ACAO ${r.acao})` : ""}`);
    if (r.status >= 500) dev.push(`${r.id}. ${r.label}: server error ${r.status}`);
    else if (!ok) dev.push(`${r.id}. ${r.label}: expected ${({ "2xx": "2xx", "400": "400", "403": "401/403", "silent-2xx": "a silent 2xx", preflight: "2xx" })[r.expect]}, got ${r.status}`);
    if (r.acao === "*") dev.push(`${r.id}. ${r.label}: Access-Control-Allow-Origin is a wildcard`);
    if (r.id === 6 && r.acao && r.acao === r.sentOrigin) dev.push(`6. ${r.label}: the disallowed origin was echoed in Access-Control-Allow-Origin`);
    if (r.id === 7 && r.status >= 200 && r.status < 300 && r.acao !== origin && r.acao !== "*") dev.push(`7. ${r.label}: preflight did not allow the site's own origin (ACAO ${r.acao ?? "absent"})`);
  }
  const note = "Cases 4 and 5 are expected to answer 2xx without storing anything; whether a bot submission was stored cannot be seen from outside without a verification hook, so that part is not verified.";
  if (dev.length === 0)
    return { findings: [], checks: [{ rule_id: "FORM-010", outcome: "passed", detail: `Endpoint behaved as expected. ${lines.join("; ")}. ${note}`, evidence_keys: [evidenceKey] }] };
  return {
    findings: [{
      rule_id: "FORM-010", severity: "medium", title: "Form endpoint behaved unexpectedly under test", location: "endpoint-matrix", page_url: origin, confidence: "high",
      detail: `${dev.length} deviation${dev.length === 1 ? "" : "s"} from the expected behaviour: ${dev.join("; ")}. Test data used the markers "${MARKER_NAME}" and ${MARKER_EMAIL}; delete any stored copies.`,
      evidence_keys: [evidenceKey],
    }],
    checks: [{ rule_id: "FORM-010", outcome: "finding", detail: `${dev.length} deviation${dev.length === 1 ? "" : "s"}. ${lines.join("; ")}.`, evidence_keys: [evidenceKey] }],
  };
}

// FORM-011. `res` comes from liveSubmit below. Delivery to the owner is never claimed here.
export function evaluateLiveSubmit({ res, origin, evidenceKey = "active_submit" }) {
  const cleanup = `Test data used: name "${MARKER_NAME}", email ${MARKER_EMAIL}, phone ${MARKER_PHONE}. Delete any submission containing those strings.`;
  const posts = (res.responses ?? []).filter((r) => r.method !== "GET");
  const ok2xx = posts.some((r) => r.status >= 200 && r.status < 300);
  if (res.error) return { findings: [], checks: [{ rule_id: "FORM-011", outcome: "skipped", detail: `Could not run: ${res.error}. ${cleanup}`, evidence_keys: [evidenceKey] }] };
  if (res.success && ok2xx)
    return { findings: [], checks: [{ rule_id: "FORM-011", outcome: "passed", detail: `The page showed a success state and the endpoint answered ${posts.find((r) => r.status >= 200 && r.status < 300).status}. Delivery not verified: confirm the notification arrived at the intended inbox. ${cleanup}`, evidence_keys: [evidenceKey] }] };
  const why = !posts.length ? "no request was sent when the form was submitted" : !ok2xx ? `the endpoint answered ${posts.map((r) => r.status).join(", ")}` : "the page showed no success state";
  return {
    findings: [{
      rule_id: "FORM-011", severity: "high", title: "The live form submission test did not complete", location: "live-submit", page_url: res.pageUrl ?? origin, confidence: "high",
      detail: `The real form was filled with test data and submitted in the browser, but ${why}${res.success ? "" : "; no success message appeared"}. ${cleanup}`,
      evidence_keys: [evidenceKey],
    }],
    checks: [{ rule_id: "FORM-011", outcome: "finding", detail: `${why}. ${cleanup}`, evidence_keys: [evidenceKey] }],
  };
}
