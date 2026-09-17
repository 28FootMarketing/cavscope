// AVAIL-003: a site that answers and refuses the scanner is not an outage.
//
//   node --experimental-strip-types --test tests/scan/avail-refused.test.ts
//
// studyfetch.com returned HTTP 403 to MUSTER-Scanner/1.0 while the plain-HTTP
// probe got a normal 301 -- a WAF or bot filter declining our user agent, on a
// site that is up. AVAIL-001 called that critical "Site unreachable", and the
// SITREP told the reader "Visitors cannot load the site. Nothing else matters
// until this is fixed," with remediation pointing at DNS, hosting and TLS.
//
// Every clause of that is false for a site that is running, and it is the
// failure this codebase treats as the worst available: a confident claim about
// a page the engine never read. The mirror of issue #93.
//
// The engine source is the subject here rather than a pure module, because the
// branch lives in runScan() where the status is known.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const engine = readFileSync(join(repoRoot, "supabase", "functions", "muster-scan", "index.ts"), "utf8");

test("only 401, 403 and 429 are treated as refusal", () => {
  // A 404 homepage is genuinely broken and a 5xx is genuinely an outage. Both
  // must stay on AVAIL-001, or the fix becomes a way to hide real outages.
  assert.match(engine, /const refused = !primary\.error && \(primary\.status === 401 \|\| primary\.status === 403 \|\| primary\.status === 429\);/);
});

test("a transport error is never a refusal", () => {
  // No status at all means nothing answered. That is AVAIL-001 and must not be
  // reported as "the server declined us".
  assert.match(engine, /const refused = !primary\.error &&/);
});

test("refused and unreachable are mutually exclusive", () => {
  // else-if, not two independent ifs: a refused scan must not also raise
  // AVAIL-001, which would double-count the severity and score the site twice.
  const block = engine.slice(engine.indexOf("const refused ="), engine.indexOf("AVAIL-002"));
  assert.match(block, /if \(refused\) \{[\s\S]*\} else if \(!reachable\) \{/);
  assert.equal((block.match(/rule_id: "AVAIL-003"/g) || []).length, 1);
  assert.equal((block.match(/rule_id: "AVAIL-001"/g) || []).length, 1);
});

test("AVAIL-003 keeps critical severity, and the reason is written down", () => {
  // Severity drives posture: critical 25, high 10, medium 4, low 1, off 100,
  // green at 85. Filing a refused scan as low would score an unreadable site
  // 99 and render it GREEN -- absence of findings read as a pass, which is
  // exactly what migration 062 exists to prevent.
  assert.match(engine, /rule_id: "AVAIL-003", severity: "critical"/);
  assert.match(engine, /score an unreadable site 99\/100 green/);
});

test("the finding states it is not an assessment, and does not diagnose", () => {
  const block = engine.slice(engine.indexOf('rule_id: "AVAIL-003"'), engine.indexOf("} else if (!reachable)"));
  assert.match(block, /could not be assessed/i);
  // It reports what happened and names bot protection as the common cause
  // without asserting it -- one request cannot tell that apart from a 403
  // served to everyone.
  assert.match(block, /commonly a WAF, CDN bot filter or rate limiter/);
  assert.match(block, /reflects an unassessed target rather than a clean one/);
  // And it must not repeat AVAIL-001's false claim.
  assert.doesNotMatch(block, /Visitors cannot load/);
});

test("the engine version moved, because rule output changed", () => {
  // Pinned on purpose. ENGINE_VERSION is only ever compared to itself, so
  // nothing fails when it does not move -- this test is the thing that fails.
  // 1.5.0 adds EMAIL-009; AVAIL-003's own line is asserted below so the
  // changelog cannot lose an entry as versions accumulate.
  assert.match(engine, /const ENGINE_VERSION = "http-native-1\.5\.0";/);
  assert.match(engine, /1\.4\.0 adds AVAIL-003/);
  assert.match(engine, /1\.5\.0 adds EMAIL-009/);
});

test("the rule shipped inactive and was activated in a separate migration", () => {
  // The standing rule: a rule waits for its engine. Added inactive, deployed,
  // then activated is three observable states, and the ingest guard in
  // 20260917061404 is what makes the wait real rather than decorative.
  const add = readFileSync(join(repoRoot, "supabase", "migrations", "20260917071020_muster_065_avail003_scanner_refused.sql"), "utf8");
  const activate = readFileSync(join(repoRoot, "supabase", "migrations", "20260917071751_muster_066_activate_avail003.sql"), "utf8");
  assert.match(add, /'AVAIL-003',[\s\S]*\n  false\n\)/);
  assert.match(activate, /set active = true[\s\S]*where rule_id = 'AVAIL-003'/);
  assert.ok(add.indexOf("AVAIL-003") > 0 && activate.indexOf("AVAIL-003") > 0);
});
