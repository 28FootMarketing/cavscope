// SEC-019 rule logic, tested against the shipped module -- NOT wired into
// index.ts, and there is no path to wire it from this engine's transport.
//
//   node --experimental-strip-types --test tests/scan/methods.test.ts
//
// fetch() throws `TypeError: Method is forbidden` for TRACE, TRACK and
// CONNECT. Confirmed empirically against Deno 2.9.7 (the runtime
// supabase/functions/muster-scan runs on), and it is the WHATWG Fetch spec's
// own forbidden-method list, not a Deno-specific restriction, so no
// spec-compliant fetch() can send a TRACE request. index.ts's own DNS
// section explains why a raw-socket fallback is not available either: DNS
// goes over DNS-over-HTTPS "because the edge runtime does not expose a
// resolver, and [...] an HTTPS call is subject to the same egress rules as
// everything else here" -- fetch() is the only egress this runtime grants.
//
// This module and its tests are kept anyway, for the same reason a held-
// inactive scan_rules row is kept rather than deleted: the pure logic is
// correct and worth having on record if a future transport (a raw-socket
// helper proven to work inside the deployed function, not just the Deno
// CLI) ever makes SEC-019 reachable. Until then it should be treated as
// retired, not merely unscheduled -- see ENGINE_VERSION's 1.8.0 note in
// index.ts.

import { test } from "node:test";
import assert from "node:assert/strict";
import { evaluateTraceMethod, traceEchoed, type TraceProbeResult } from "../../supabase/functions/muster-scan/methods.ts";

test("traceEchoed is false when the marker is absent even on a 200", () => {
  const r: TraceProbeResult = { status: 200, body: "HTTP/1.1 200 OK\r\nContent-Type: message/http\r\n\r\nTRACE / HTTP/1.1\r\nHost: example.com", sentMarker: "muster-trace-9f3a" };
  assert.equal(traceEchoed(r), false);
});

test("traceEchoed is false on a non-200 status even if the marker appears in the body", () => {
  // A WAF's own block page could coincidentally echo request fragments; the
  // status gate is what keeps that from being misread as an origin echo.
  const r: TraceProbeResult = { status: 403, body: "Forbidden by WAF. Request-Id: muster-trace-9f3a", sentMarker: "muster-trace-9f3a" };
  assert.equal(traceEchoed(r), false);
});

test("traceEchoed is true only for a 200 whose body contains this scan's own marker", () => {
  const r: TraceProbeResult = { status: 200, body: "HTTP/1.1 200 OK\r\n\r\nTRACE / HTTP/1.1\r\nX-Muster-Trace-Probe: muster-trace-9f3a\r\n", sentMarker: "muster-trace-9f3a" };
  assert.equal(traceEchoed(r), true);
});

test("evaluateTraceMethod raises nothing when TRACE is not echoed", () => {
  const r: TraceProbeResult = { status: 405, body: "Method Not Allowed", sentMarker: "muster-trace-9f3a" };
  assert.deepEqual(evaluateTraceMethod({ result: r, evidenceKey: "trace_probe" }), []);
});

test("evaluateTraceMethod raises one low-severity SEC-019 finding when TRACE is echoed", () => {
  const r: TraceProbeResult = { status: 200, body: "TRACE / HTTP/1.1\r\nX-Muster-Trace-Probe: muster-trace-9f3a\r\n", sentMarker: "muster-trace-9f3a" };
  const out = evaluateTraceMethod({ result: r, evidenceKey: "trace_probe" });
  assert.equal(out.length, 1);
  assert.equal(out[0].rule_id, "SEC-019");
  assert.equal(out[0].severity, "low");
  assert.equal(out[0].evidence_keys[0], "trace_probe");
});
