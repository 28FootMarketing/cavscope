// SEC-018 rule logic, tested against the shipped module.
//
//   node --experimental-strip-types --test tests/scan/csp.test.ts
//
// Wired into index.ts right after the SEC-004 check as of ENGINE_VERSION
// http-native-1.8.0. Held inactive in muster.scan_rules until a scan reports
// that version live -- see supabase/migrations/
// 20260923190000_muster_086_hardening_gap_rules_inactive.sql.
//
// SEC-004 and SEC-018 are mutually exclusive by construction: a null/absent
// CSP must never also raise SEC-018, or one defect (no policy at all) would
// be scored twice under two rule_ids -- the same discipline login.ts's
// AUTH-*/SEC-005/SEC-011 split already enforces.

import { test } from "node:test";
import assert from "node:assert/strict";
import { evaluateCspQuality } from "../../supabase/functions/muster-scan/csp.ts";

test("no finding when csp is null -- that case belongs to SEC-004 alone", () => {
  assert.deepEqual(evaluateCspQuality({ csp: null, evidenceKey: "headers" }), []);
});

test("no finding for a well-scoped policy with no unsafe keywords", () => {
  const csp = "default-src 'self'; script-src 'self' https://cdn.example.com; object-src 'none'";
  assert.deepEqual(evaluateCspQuality({ csp, evidenceKey: "headers" }), []);
});

test("fires on 'unsafe-inline' in script-src", () => {
  const csp = "default-src 'self'; script-src 'self' 'unsafe-inline'";
  const out = evaluateCspQuality({ csp, evidenceKey: "headers" });
  assert.equal(out.length, 1);
  assert.equal(out[0].rule_id, "SEC-018");
  assert.equal(out[0].severity, "medium");
  assert.match(out[0].detail, /unsafe-inline/);
  assert.match(out[0].detail, /script-src/);
});

test("fires on 'unsafe-eval' in script-src", () => {
  const csp = "script-src 'self' 'unsafe-eval'";
  const out = evaluateCspQuality({ csp, evidenceKey: "headers" });
  assert.equal(out.length, 1);
  assert.match(out[0].detail, /unsafe-eval/);
});

test("fires on a bare wildcard script source", () => {
  const csp = "script-src *";
  const out = evaluateCspQuality({ csp, evidenceKey: "headers" });
  assert.equal(out.length, 1);
  assert.match(out[0].detail, /any host/);
});

test("does NOT fire on a scoped wildcard host -- only a bare '*' token counts", () => {
  const csp = "script-src 'self' *.trusted-cdn.example.com";
  assert.deepEqual(evaluateCspQuality({ csp, evidenceKey: "headers" }), []);
});

test("falls back to default-src when script-src is absent, per the CSP spec's own fallback rule", () => {
  const csp = "default-src 'self' 'unsafe-inline'";
  const out = evaluateCspQuality({ csp, evidenceKey: "headers" });
  assert.equal(out.length, 1);
  assert.match(out[0].detail, /default-src/);
});

test("script-src, when present, governs even if default-src is also unsafe -- script-src is what actually executes script", () => {
  const csp = "default-src 'unsafe-inline'; script-src 'self'";
  assert.deepEqual(evaluateCspQuality({ csp, evidenceKey: "headers" }), []);
});

test("fires when neither script-src nor default-src is present at all -- script execution is unrestricted", () => {
  const csp = "frame-ancestors 'self'";
  const out = evaluateCspQuality({ csp, evidenceKey: "headers" });
  assert.equal(out.length, 1);
  assert.match(out[0].detail, /no script-src or default-src/);
});

test("does not substring-match 'unsafe-inline' inside an unrelated token, e.g. a nonce value", () => {
  // A directive value is a space-separated source list; a token that merely
  // contains the keyword's text is not the keyword.
  const csp = "script-src 'self' 'nonce-totally-unsafe-inline-looking-but-not-abc123'";
  assert.deepEqual(evaluateCspQuality({ csp, evidenceKey: "headers" }), []);
});

test("multiple problems in one directive are reported together, once", () => {
  const csp = "script-src * 'unsafe-inline' 'unsafe-eval'";
  const out = evaluateCspQuality({ csp, evidenceKey: "headers" });
  assert.equal(out.length, 1);
  assert.match(out[0].detail, /unsafe-inline/);
  assert.match(out[0].detail, /unsafe-eval/);
  assert.match(out[0].detail, /any host/);
});
