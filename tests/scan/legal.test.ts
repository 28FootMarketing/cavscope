// PRIV-004 and the jurisdiction signal: crediting a Terms of Service link the
// way PRIV-001 already credits a privacy policy, and reading the US state a
// site states about ITSELF, so muster.q_sitrep_jurisdiction stops reading the
// scanning workspace's own region_code for every ad-hoc URL parked in the
// admin sandbox org. See legal.ts's header for the full failure this fixes.
//
//   node --experimental-strip-types --test tests/scan/legal.test.ts
//
// This file owns the ENGINE_VERSION equality pin (CLAUDE.md: the newest
// rule's test owns it); tests/scan/aio.test.ts and login.test.ts assert
// floors.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { extractUsState } from "../../supabase/functions/muster-scan/legal.ts";
import { loadEngine } from "../../tools/local-scan/adapt.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const engine = readFileSync(join(ROOT, "supabase/functions/muster-scan/index.ts"), "utf8");

test("a governing-law clause is read over an address when both are present", () => {
  const v = extractUsState(`<footer>123 Main St, Wilmington, DE 19801. This site is governed by the laws of the State of California, without regard to conflicts of law.</footer>`);
  assert.equal(v.code, "CA");
  assert.match(v.reason, /Governing-law clause/);
});

test("a governing-law clause needs a known state name, and does not overmatch", () => {
  assert.equal(extractUsState("governed by the laws of the State of Delaware.").code, "DE");
  assert.equal(extractUsState("governed by the laws of the Commonwealth of Pennsylvania and applicable federal law").code, "PA");
  assert.equal(extractUsState("governed by the laws of Mars").code, null);
});

test("a postal address is read when there is no governing-law clause", () => {
  const v = extractUsState("Contact us: After Today LLC, 123 Main St, Hanover, PA 17331. Email: hello@example.com");
  assert.equal(v.code, "PA");
  assert.match(v.reason, /Postal address/);
});

test("an address with an unrecognised two-letter code is not credited as a state", () => {
  // "Suite ZZ" is not a state, and the regex must not treat any two capital
  // letters before five digits as a US state code.
  assert.equal(extractUsState("Reference: ZZ 90210").code, null);
});

test("no governing-law clause or address returns null, never a guess", () => {
  const v = extractUsState("<p>Welcome to our site. We sell widgets.</p>");
  assert.equal(v.code, null);
  assert.equal(v.name, null);
});

test("PRIV-004 mirrors PRIV-001: same anchors, same csrNote, same evidence key", () => {
  const start = engine.indexOf("// Privacy policy link");
  const end = engine.indexOf("// Scripts, trackers, mixed content");
  assert.ok(start > 0 && end > start);
  const section = engine.slice(start, end);
  assert.match(section, /rule_id: "PRIV-001"/);
  assert.match(section, /rule_id: "PRIV-004"/);
  assert.match(section, /\\bterms\\b\|\\btos\\b/);
});

test("the jurisdiction follow-up only fetches a same-origin legal page", () => {
  const start = engine.indexOf("// Jurisdiction signal");
  const end = engine.indexOf("// Scripts, trackers, mixed content");
  assert.ok(start > 0 && end > start);
  const section = engine.slice(start, end);
  assert.match(section, /legalUrl\.hostname\.toLowerCase\(\) === host/);
  assert.match(section, /key: "legal_page", kind: "html_excerpt"/);
});

test("end to end: no legal links and no state info raises PRIV-001 and PRIV-004, and reports no jurisdiction", async () => {
  const server = createServer((_req, res) => {
    res.writeHead(200, { "content-type": "text/html" });
    res.end(`<!doctype html><html lang="en"><head><title>T</title></head><body><h1>Hi</h1><p>${"body copy ".repeat(40)}</p></body></html>`);
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
  const { port } = server.address() as AddressInfo;
  try {
    const mod = await import(await loadEngine()) as {
      runScan: (job: { scan_id: number; website_id: number; target_url: string; website_name: string }) =>
        Promise<{ findings: Array<{ rule_id: string }>; scan: { detected_country_code: string | null; detected_region_code: string | null } }>;
    };
    const result = await mod.runScan({ scan_id: 0, website_id: 0, target_url: `http://127.0.0.1:${port}/`, website_name: "t" });
    const ids = new Set(result.findings.map((f) => f.rule_id));
    assert.ok(ids.has("PRIV-001"), "PRIV-001 should fire with no privacy link");
    assert.ok(ids.has("PRIV-004"), "PRIV-004 should fire with no terms link");
    assert.equal(result.scan.detected_country_code, null);
    assert.equal(result.scan.detected_region_code, null);
  } finally {
    server.close();
  }
});

test("end to end: a terms link to a same-origin page with a governing-law clause is credited and read", async () => {
  const server = createServer((req, res) => {
    if (req.url === "/terms") {
      res.writeHead(200, { "content-type": "text/html" });
      return res.end(`<!doctype html><html><body><p>These Terms of Service are governed by the laws of the State of Texas.</p></body></html>`);
    }
    res.writeHead(200, { "content-type": "text/html" });
    res.end(`<!doctype html><html lang="en"><head><title>T</title></head><body><h1>Hi</h1><a href="/terms">Terms of Service</a><p>${"body copy ".repeat(40)}</p></body></html>`);
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
  const { port } = server.address() as AddressInfo;
  try {
    const mod = await import(await loadEngine()) as {
      runScan: (job: { scan_id: number; website_id: number; target_url: string; website_name: string }) =>
        Promise<{ findings: Array<{ rule_id: string }>; evidence: Array<{ key: string }>; scan: { detected_country_code: string | null; detected_region_code: string | null } }>;
    };
    const result = await mod.runScan({ scan_id: 0, website_id: 0, target_url: `http://127.0.0.1:${port}/`, website_name: "t" });
    const ids = new Set(result.findings.map((f) => f.rule_id));
    assert.ok(!ids.has("PRIV-004"), "PRIV-004 must not fire when a terms link is present");
    assert.ok(result.evidence.some((e) => e.key === "legal_page"), "legal_page evidence must be written when the follow-up page is fetched");
    assert.equal(result.scan.detected_country_code, "US");
    assert.equal(result.scan.detected_region_code, "TX");
  } finally {
    server.close();
  }
});

test("a legal link to a different origin is never followed", async () => {
  const server = createServer((_req, res) => {
    res.writeHead(200, { "content-type": "text/html" });
    res.end(`<!doctype html><html lang="en"><head><title>T</title></head><body><h1>Hi</h1><a href="https://example.com/terms">Terms of Service</a><p>${"body copy ".repeat(40)}</p></body></html>`);
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
  const { port } = server.address() as AddressInfo;
  try {
    const mod = await import(await loadEngine()) as {
      runScan: (job: { scan_id: number; website_id: number; target_url: string; website_name: string }) =>
        Promise<{ evidence: Array<{ key: string; url: string }>; scan: { detected_region_code: string | null } }>;
    };
    const result = await mod.runScan({ scan_id: 0, website_id: 0, target_url: `http://127.0.0.1:${port}/`, website_name: "t" });
    assert.ok(!result.evidence.some((e) => e.key === "legal_page"), "a cross-origin legal link must never be fetched");
    assert.equal(result.scan.detected_region_code, null);
  } finally {
    server.close();
  }
});

test("the engine version moved with the rule set", () => {
  // A finding's severity is only comparable across scans on the same version.
  assert.match(engine, /const ENGINE_VERSION = "http-native-1\.11\.0";/);
  assert.match(engine, /1\.11\.0 adds PRIV-004 \(no Terms of Service link found/);
});
