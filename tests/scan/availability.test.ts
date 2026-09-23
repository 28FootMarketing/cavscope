// AVAIL-004: a response the client refused to parse is not an outage.
//
//   node --experimental-strip-types --test tests/scan/availability.test.ts
//
// hpsd.k12.pa.us answered the engine's HTTPS request with
// `client error (SendRequest): invalid HTTP header parsed`. AVAIL-001 filed that
// as a critical "Site unreachable or returning an error", whose plain-English
// line reads "Visitors cannot load the site" -- while the same site returned
// HTTP 200 to a lenient client, and while this engine's own plain-HTTP probe
// got 200 from the same host in the same scan and raised SEC-001 about it.
//
// So the report simultaneously said the site was down and reported on its
// redirect behaviour. That is the failure this codebase treats as the worst
// available: a confident claim about a page the engine never read.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { responseRejectedByClient, RESPONSE_PARSE_MARKER_LIST } from "../../supabase/functions/muster-scan/availability.ts";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const engine = readFileSync(join(repoRoot, "supabase", "functions", "muster-scan", "index.ts"), "utf8");

test("the error that found this is classified as a parse failure", () => {
  // Verbatim from scan 60 against https://hpsd.k12.pa.us/ on 2026-09-17.
  assert.equal(
    responseRejectedByClient(
      "TypeError: error sending request from 10.32.215.168:34286 for https://hpsd.k12.pa.us/ (208.67.143.164:443): client error (SendRequest): invalid HTTP header parsed",
    ),
    true,
  );
});

test("failures that happen before a response exists stay on AVAIL-001", () => {
  // Each of these is raised before any response bytes arrive, so none of them
  // is evidence that a server answered. Misclassifying one would hide a real
  // outage behind "could not be assessed", which is worse than the defect
  // AVAIL-004 fixes.
  for (const err of [
    "TypeError: error sending request for url (https://x.example/): client error (Connect): dns error: failed to lookup address information: Name or service not known",
    "TypeError: error sending request for url (https://x.example/): client error (Connect): tcp connect error: Connection refused (os error 111)",
    "TypeError: error sending request for url (https://x.example/): client error (Connect): invalid peer certificate: UnknownIssuer",
    "DOMException: The signal has been aborted",
    "TypeError: error sending request: connection closed before message completed",
  ]) {
    assert.equal(responseRejectedByClient(err), false, err);
  }
});

test("no error at all is not a parse failure", () => {
  assert.equal(responseRejectedByClient(null), false);
  assert.equal(responseRejectedByClient(undefined), false);
  assert.equal(responseRejectedByClient(""), false);
});

test("matching is case-insensitive", () => {
  assert.equal(responseRejectedByClient("client error: Invalid HTTP Header Parsed"), true);
});

test("every marker is one a client can only raise after a response arrived", () => {
  // A marker naming a connect, DNS or TLS phase would break the premise the
  // rule rests on -- that a match proves a server answered.
  for (const m of RESPONSE_PARSE_MARKER_LIST) {
    assert.doesNotMatch(m, /connect|dns|certificate|handshake|refused|timed out|abort/i, m);
  }
  assert.ok(RESPONSE_PARSE_MARKER_LIST.length > 0);
});

test("the engine branches on it, ahead of AVAIL-001 and after AVAIL-003", () => {
  const block = engine.slice(engine.indexOf("const refused ="), engine.indexOf('rule_id: "AVAIL-002"'));
  assert.match(block, /const unparsable = !refused && responseRejectedByClient\(primary\.error\);/);
  // One chain, not three independent ifs: a site must raise exactly one of
  // these, or an unreadable scan is scored twice for the same fact.
  assert.match(block, /if \(refused\) \{[\s\S]*\} else if \(unparsable\) \{[\s\S]*\} else if \(!reachable\) \{/);
  assert.equal((block.match(/rule_id: "AVAIL-004"/g) || []).length, 1);
});

test("AVAIL-004 keeps critical severity, and says why the score is not a pass", () => {
  // Same reasoning as AVAIL-003: critical 25, high 10, medium 4, low 1, off
  // 100, green at 85. A lighter weight would score a site nobody could read at
  // 99/100 and render it GREEN.
  assert.match(engine, /rule_id: "AVAIL-004", severity: "critical"/);
  const block = engine.slice(engine.indexOf('rule_id: "AVAIL-004"'), engine.indexOf("} else if (!reachable)"));
  assert.match(block, /unassessed target rather than a clean one/);
  assert.match(block, /not an outage/);
  // It must carry the raw client error rather than paraphrasing it: the string
  // is the only thing that tells the reader which parser rejected what.
  assert.match(block, /\$\{primary\.error\}/);
});

test("the engine version is past the one this rule shipped in", () => {
  // A floor, not an equality: the equality pin belongs to the newest rule's
  // test (tests/scan/login.test.ts since 1.7.0), so a later bump edits one
  // file instead of every rule's. What this change established is that the
  // version reached 1.6.0 and its changelog line says why.
  const m = engine.match(/const ENGINE_VERSION = "http-native-(\d+)\.(\d+)\.(\d+)";/);
  assert.ok(m, "ENGINE_VERSION is not in the expected http-native-x.y.z form");
  const [major, minor] = [Number(m[1]), Number(m[2])];
  assert.ok(major > 1 || (major === 1 && minor >= 6), `AVAIL-004 shipped in 1.6.0; found ${m[0]}`);
  assert.match(engine, /1\.6\.0 adds AVAIL-004/);
});
