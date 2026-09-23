// SEC-019: TRACE/TRACK HTTP method enabled.
//
// NOT WIRED, AND NOT WIREABLE from this engine's transport. Confirmed
// empirically against Deno 2.9.7: fetch(url, { method: "TRACE" }) throws
// `TypeError: Method is forbidden` -- TRACE, TRACK and CONNECT are on the
// WHATWG Fetch spec's own forbidden-method list, so no spec-compliant
// fetch() implementation can send one, in any runtime. index.ts's
// ENGINE_VERSION comment for 1.8.0 covers why a raw-socket fallback is not
// an answer either: this engine's egress is fetch()-only (the same reason
// DNS goes over DNS-over-HTTPS instead of Deno.resolveDns), and that has
// not been shown to be false inside the deployed function specifically.
//
// Kept, rather than deleted, for the same reason a held-inactive
// scan_rules row is kept: the logic below is correct and worth having on
// record if a future transport ever makes this reachable. Treat it as
// retired, not merely unscheduled, until someone does that work.
//
// WHY A MARKER, NOT JUST STATUS 200
//
// TRACE is defined by RFC 9110 to have the origin server reflect the exact
// request it received back as the response body. A 200 alone does not prove
// that happened: a CDN, WAF or reverse proxy in front of the origin may
// answer TRACE with its own 200 page (a custom error, a cached response)
// without ever forwarding the verb to the origin server that actually needs
// fixing. Sending a marker value nothing else would produce -- and requiring
// it to appear in the echoed body -- is the same discipline AUTH-004/
// AUTH-005 use a content signature for, applied to a verb instead of a path:
// a status code proves a response arrived, not what produced it.
//
// This is rated low, not higher, because TRACE alone does not expose
// anything by itself. It becomes exploitable (Cross-Site Tracing) only
// combined with a second, unrelated vulnerability -- a reflected or stored
// XSS on the same origin that a same-origin script could not otherwise use
// to read an HttpOnly cookie. The finding says so rather than presenting
// TRACE as an exploit in its own right.

export type Severity = "critical" | "high" | "medium" | "low" | "info";

export type MethodFinding = {
  rule_id: string;
  severity: Severity;
  title: string;
  detail: string;
  location: string;
  confidence: "high" | "medium" | "low";
  evidence_keys: string[];
};

export type TraceProbeResult = {
  status: number | null;
  body: string;
  /** The unique per-scan value index.ts sent in a request header, e.g. X-Muster-Trace-Probe. */
  sentMarker: string;
};

/** Whether the response body proves the origin echoed this scan's own TRACE request, not a proxy's stand-in page. */
export function traceEchoed(r: TraceProbeResult): boolean {
  return r.status === 200 && r.body.includes(r.sentMarker);
}

export function evaluateTraceMethod(input: {
  result: TraceProbeResult;
  evidenceKey: string;
}): MethodFinding[] {
  if (!traceEchoed(input.result)) return [];

  return [{
    rule_id: "SEC-019",
    severity: "low",
    title: "TRACE/TRACK HTTP method enabled",
    detail: "The server accepted an HTTP TRACE request and echoed it back verbatim in the response body, confirmed by a marker unique to this scan rather than by status code alone. On its own this exposes nothing; combined with a cross-site scripting flaw elsewhere on the same origin, TRACE can be used to read request headers -- including a cookie marked HttpOnly -- that script cannot otherwise access.",
    location: "TRACE /",
    confidence: "high",
    evidence_keys: [input.evidenceKey],
  }];
}
