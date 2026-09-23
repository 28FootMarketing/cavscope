// SEC-017 rule logic, tested against the shipped module.
//
//   node --experimental-strip-types --test tests/scan/cors.test.ts
//
// Wired into index.ts as section 3b as of ENGINE_VERSION http-native-1.8.0.
// Held inactive in muster.scan_rules until a scan reports that version live
// -- see supabase/migrations/20260923190000_muster_086_hardening_gap_rules_inactive.sql.
//
// The one thing worth getting right here is what is NOT flagged. A wildcard
// Access-Control-Allow-Origin, or a reflected Origin with no credentials, is
// not exploitable -- browsers refuse to honour credentials against a
// wildcard, and a non-credentialed cross-origin read exposes nothing a public
// resource was not already exposing. Flagging either would be the same
// category of error EMAIL-002 avoids by leaving SPF's ~all alone.

import { test } from "node:test";
import assert from "node:assert/strict";
import { PROBE_ORIGIN, evaluateCors, type CorsProbeResult } from "../../supabase/functions/muster-scan/cors.ts";

test("PROBE_ORIGIN sits on the .invalid TLD, reserved to never be a real registrable domain", () => {
  assert.match(PROBE_ORIGIN, /^https:\/\/[a-z0-9-]+\.invalid$/);
});

test("no finding when Access-Control-Allow-Origin is absent", () => {
  const result: CorsProbeResult = { probedOrigin: PROBE_ORIGIN, allowOrigin: null, allowCredentials: true };
  assert.deepEqual(evaluateCors({ result, evidenceKey: "cors_probe" }), []);
});

test("no finding for a bare wildcard, even with credentials claimed true -- browsers refuse that combination outright", () => {
  const result: CorsProbeResult = { probedOrigin: PROBE_ORIGIN, allowOrigin: "*", allowCredentials: true };
  assert.deepEqual(evaluateCors({ result, evidenceKey: "cors_probe" }), []);
});

test("no finding when the probed origin is reflected but credentials are not allowed", () => {
  const result: CorsProbeResult = { probedOrigin: PROBE_ORIGIN, allowOrigin: PROBE_ORIGIN, allowCredentials: false };
  assert.deepEqual(evaluateCors({ result, evidenceKey: "cors_probe" }), []);
});

test("no finding when Access-Control-Allow-Origin names something other than the probed origin", () => {
  const result: CorsProbeResult = { probedOrigin: PROBE_ORIGIN, allowOrigin: "https://trusted-partner.example.com", allowCredentials: true };
  assert.deepEqual(evaluateCors({ result, evidenceKey: "cors_probe" }), []);
});

test("SEC-017 fires on exact reflection of the probed origin plus Allow-Credentials: true", () => {
  const result: CorsProbeResult = { probedOrigin: PROBE_ORIGIN, allowOrigin: PROBE_ORIGIN, allowCredentials: true };
  const out = evaluateCors({ result, evidenceKey: "cors_probe" });
  assert.equal(out.length, 1);
  assert.equal(out[0].rule_id, "SEC-017");
  assert.equal(out[0].severity, "high");
  assert.equal(out[0].evidence_keys[0], "cors_probe");
  assert.match(out[0].detail, /cors-probe\.invalid/);
});

test("reflection match is case-insensitive on the origin string", () => {
  const result: CorsProbeResult = { probedOrigin: PROBE_ORIGIN, allowOrigin: PROBE_ORIGIN.toUpperCase(), allowCredentials: true };
  const out = evaluateCors({ result, evidenceKey: "cors_probe" });
  assert.equal(out.length, 1);
});

test("stray whitespace around the reflected origin does not defeat the match", () => {
  const result: CorsProbeResult = { probedOrigin: PROBE_ORIGIN, allowOrigin: `  ${PROBE_ORIGIN}  `, allowCredentials: true };
  const out = evaluateCors({ result, evidenceKey: "cors_probe" });
  assert.equal(out.length, 1);
});
