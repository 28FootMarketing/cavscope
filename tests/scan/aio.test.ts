// GOV-006..008: the AI-readiness checks behind the workspace's AIO view.
//
//   node --experimental-strip-types --test tests/scan/aio.test.ts
//
// Until http-native-1.8.0 the view scored llms.txt and structured data that the
// engine never requested, and printed the same scripted verdicts for every
// domain. The failure these tests guard is the same one in both directions:
// crediting a site with a file it does not have (an SPA's catch-all 200), and
// accusing a site of lacking one it has.
//
// This file owns the ENGINE_VERSION equality pin (CLAUDE.md: the newest rule's
// test owns it); login.test.ts and the AVAIL-* tests assert floors.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { assessLlmsTxt, summarizeJsonLd } from "../../supabase/functions/muster-scan/aio.ts";
import { loadEngine } from "../../tools/local-scan/adapt.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const engine = readFileSync(join(ROOT, "supabase/functions/muster-scan/index.ts"), "utf8");

const res = (status: number | null, body = "", contentType: string | null = "text/plain") => ({ status, body, contentType });

test("a real llms.txt passes", () => {
  const v = assessLlmsTxt(res(200, "\n# Acme Borough\n\n> Municipal services.\n\n## Docs\n- [Permits](https://acme.test/permits)\n", "text/markdown"));
  assert.equal(v.ok, true);
  assert.match(v.reason, /Acme Borough/);
});

test("an SPA's catch-all 200 is not an llms.txt", () => {
  // The expensive direction: crediting every single-page app with the file.
  assert.equal(assessLlmsTxt(res(200, "<!doctype html><html><body><div id=root></div></body></html>", "text/html; charset=utf-8")).ok, false);
  // Mislabelled content type, still HTML.
  assert.equal(assessLlmsTxt(res(200, "<!DOCTYPE html><html></html>", "text/plain")).ok, false);
});

test("absent, redirected, empty or headless files fail with a reason a reader can act on", () => {
  assert.match(assessLlmsTxt(res(404, "not found")).reason, /^HTTP 404$/);
  assert.match(assessLlmsTxt(res(301)).reason, /redirect/);
  assert.match(assessLlmsTxt(res(200, "   \n\n")).reason, /empty/);
  assert.match(assessLlmsTxt(res(200, "User-agent: *\nDisallow:\n")).reason, /H1/);
  assert.match(assessLlmsTxt({ status: null, body: "", contentType: null, error: "connection reset" }).reason, /request failed \(connection reset\)/);
});

test("JSON-LD types are read from top level and @graph, not from nested properties", () => {
  const html = `<head>
    <script type="application/ld+json">{"@context":"https://schema.org","@type":"Organization","name":"A","address":{"@type":"PostalAddress"}}</script>
    <script type='application/ld+json'>{"@context":"https://schema.org","@graph":[{"@type":"WebSite"},{"@type":["Product","Thing"],"offers":{"@type":"Offer"}}]}</script>
  </head>`;
  const s = summarizeJsonLd(html);
  assert.equal(s.blocks, 2);
  assert.equal(s.parsed, 2);
  assert.deepEqual(s.types, ["Organization", "Product", "Thing", "WebSite"]);
});

test("an unparseable block is counted but credits nothing", () => {
  const s = summarizeJsonLd(`<script type="application/ld+json">{"@type":"Organization",}</script>`);
  assert.deepEqual(s, { blocks: 1, parsed: 0, types: [] });
});

test("no block, and ordinary scripts, give zero", () => {
  assert.deepEqual(summarizeJsonLd(`<script>var x = {"@type":"Organization"}</script><script type="module" src="/a.js"></script>`), { blocks: 0, parsed: 0, types: [] });
});

test("the engine writes both artefacts unconditionally, with kinds the evidence CHECK accepts", () => {
  // An unknown kind fails scan_evidence_kind_check, and ingest -- and the whole
  // scan -- with it. The unconditional writes are the proof of deploy: these
  // rules are legitimately silent on a site that already does all three.
  assert.match(engine, /key: "llms_txt", kind: "http_probe"/);
  assert.match(engine, /key: "jsonld", kind: "html_excerpt"/);
  assert.match(engine, /fetchOnce\(`\$\{origin\}\/llms\.txt`, "GET"\)/);
});

test("end to end: a bare SPA raises all three; a prepared site raises none", async () => {
  let prepared = false;
  const server = createServer((req, res) => {
    if (prepared && req.url === "/llms.txt") { res.writeHead(200, { "content-type": "text/markdown" }); return res.end("# Prepared\n\n> A site.\n"); }
    if (!prepared) {
      // Catch-all: every path is the shell, llms.txt included.
      res.writeHead(200, { "content-type": "text/html" });
      return res.end(`<!doctype html><html lang="en"><head><title>App</title></head><body><div id="root"></div><script type="module" src="/a.js"></script></body></html>`);
    }
    if (req.url !== "/") { res.writeHead(404); return res.end(); }
    res.writeHead(200, { "content-type": "text/html" });
    res.end(`<!doctype html><html lang="en"><head><title>T</title><script type="application/ld+json">{"@context":"https://schema.org","@type":"Organization","name":"P"}</script></head><body><h1>Hi</h1><p>${"body copy ".repeat(40)}</p></body></html>`);
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
  const { port } = server.address() as AddressInfo;
  try {
    const mod = await import(await loadEngine()) as {
      runScan: (job: { scan_id: number; website_id: number; target_url: string; website_name: string }) =>
        Promise<{ findings: Array<{ rule_id: string; detail: string }>; evidence: Array<{ key: string; kind: string }> }>;
    };
    const job = { scan_id: 0, website_id: 0, target_url: `http://127.0.0.1:${port}/`, website_name: "t" };

    const bare = await mod.runScan(job);
    const bareIds = new Set(bare.findings.map((f) => f.rule_id));
    for (const id of ["GOV-006", "GOV-007", "GOV-008"]) assert.ok(bareIds.has(id), `${id} should fire on a bare SPA`);
    assert.match(bare.findings.find((f) => f.rule_id === "GOV-006")!.detail, /HTML page, not a text file/);
    for (const key of ["llms_txt", "jsonld"]) assert.ok(bare.evidence.some((e) => e.key === key), `${key} evidence missing`);

    prepared = true;
    const good = await mod.runScan(job);
    const goodIds = new Set(good.findings.map((f) => f.rule_id));
    for (const id of ["GOV-006", "GOV-007", "GOV-008"]) assert.ok(!goodIds.has(id), `${id} must not fire on a prepared site`);
    for (const key of ["llms_txt", "jsonld"]) assert.ok(good.evidence.some((e) => e.key === key), `${key} evidence must be written on a pass too`);
  } finally {
    server.close();
  }
});

test("the engine version moved with the rule set", () => {
  // A finding's severity is only comparable across scans on the same version.
  assert.match(engine, /const ENGINE_VERSION = "http-native-1\.8\.0";/);
  assert.match(engine, /1\.8\.0 adds GOV-006 \(no llms\.txt\), GOV-007/);
});
