import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { adaptSource, loadEngine, ENGINE_SRC } from "../../tools/local-scan/adapt.mjs";
import { postureScore, postureBand, countBySeverity } from "../../tools/local-scan/score.mjs";

// The local runner is an adapter over the deployed engine, not a second copy of
// it. These tests are what make that claim true: they pin that the adapter drops
// only the database and the request handler, that it drops no rule, and that the
// result still scans a real HTTP response end to end.

test("the adapter removes the database and the request handler, and nothing else", async () => {
  const adapted = await adaptSource();

  assert.ok(!adapted.includes("db.rpc"), "no RPC call may survive into the local engine");
  assert.ok(!adapted.includes("createClient"), "the service-role client must be gone");
  assert.ok(!adapted.includes("Deno.serve"), "the request handler must be gone");
  assert.ok(!adapted.includes("jsr:"), "no jsr: specifier may survive; Node cannot resolve one");
  assert.ok(adapted.includes("export { runScan, ENGINE_VERSION };"), "runScan must be exported");
});

test("the adapter preserves every rule in the engine", async () => {
  const original = await readFile(ENGINE_SRC, "utf8");
  const adapted = await adaptSource();

  const raises = (s: string) => s.split("add({").length - 1;
  assert.equal(raises(adapted), raises(original), "the adapted engine must raise exactly as many findings as the deployed one");

  // Every rule id in the catalog must still be present verbatim.
  const ids = [...original.matchAll(/rule_id: "([A-Z0-9-]+)"/g)].map((m) => m[1]);
  assert.ok(ids.length >= 20, "sanity: the engine should name at least 20 rule ids inline");
  for (const id of new Set(ids)) assert.ok(adapted.includes(`rule_id: "${id}"`), `${id} was lost by the adapter`);

  // The user agent identifies MUSTER to every site it touches; a local scan must
  // not appear in an operator's logs as something else.
  assert.ok(adapted.includes("MUSTER-Scanner/1.0"), "the engine user agent must be unchanged");
});

test("the adapter fails loudly rather than cutting a region it does not recognise", async () => {
  // Proven by construction: adaptSource() throws unless each anchor matches
  // exactly once. Assert the anchors are still unique in the real source, which
  // is the condition that would break first if the engine were restructured.
  const original = await readFile(ENGINE_SRC, "utf8");
  for (const anchor of [
    'import { createClient } from "jsr:@supabase/supabase-js@2";',
    'const db = createClient(Deno.env.get("SUPABASE_URL")!',
    '"./email-auth.ts"',
    'await db.rpc("muster_engine_ingest"',
  ]) {
    assert.equal(original.split(anchor).length - 1, 1, `anchor is no longer unique: ${anchor}`);
  }
});

test("the local engine scans a real response and raises the expected findings", async () => {
  const server = createServer((req, res) => {
    if (req.url === "/robots.txt") { res.writeHead(404); return res.end("no robots"); }
    res.writeHead(200, { "content-type": "text/html", "set-cookie": "sid=abc" });
    res.end(`<!doctype html><html><head></head><body><h2>no h1 here</h2>` +
      `<img src="/a.png"><form action="http://elsewhere.example/x"><input type="text"></form>` +
      `<a href="/x"></a><p>${"body copy ".repeat(40)}</p></body></html>`);
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
  const { port } = server.address() as AddressInfo;

  try {
    const engine = await import(await loadEngine()) as {
      ENGINE_VERSION: string;
      runScan: (job: { scan_id: number; website_id: number; target_url: string; website_name: string }) =>
        Promise<{ findings: Array<{ rule_id: string; severity: string }>; evidence: unknown[]; final_url: string }>;
    };
    const out = await engine.runScan({ scan_id: 0, website_id: 0, target_url: `http://127.0.0.1:${port}/`, website_name: "test" });
    const ids = new Set(out.findings.map((f) => f.rule_id));

    // Served over plain HTTP, so the critical rule fires and HSTS is not judged.
    assert.ok(ids.has("SEC-013"), "plain HTTP must raise SEC-013");
    assert.ok(!ids.has("SEC-002"), "HSTS is only judged on an HTTPS response");
    // Headers absent.
    for (const id of ["SEC-004", "SEC-005", "SEC-006", "SEC-007", "SEC-008", "SEC-011"]) {
      assert.ok(ids.has(id), `${id} should fire on a response with no security headers`);
    }
    // Markup defects.
    for (const id of ["A11Y-001", "A11Y-002", "A11Y-003", "A11Y-005", "A11Y-006", "A11Y-007", "PRIV-001", "PRIV-003"]) {
      assert.ok(ids.has(id), `${id} should fire on this markup`);
    }
    // Origin files absent.
    for (const id of ["GOV-001", "GOV-002", "SEC-012"]) assert.ok(ids.has(id), `${id} should fire`);
    // Evidence is captured, not just verdicts.
    assert.ok(out.evidence.length >= 8, "the scan must capture evidence artefacts");

    // A resolver we cannot reach must never manufacture an email finding.
    // (Offline, DoH fails and the EMAIL-* family correctly reports nothing.)
    assert.ok(!ids.has("AVAIL-001"), "the server answered, so it is not unreachable");
  } finally {
    server.close();
  }
});

test("posture scoring matches muster.posture_score", async () => {
  // 100 - sum(weights), floored at 0; critical 25, high 10, medium 4, low 1, info 0.
  assert.equal(postureScore([]), 100);
  assert.equal(postureScore([{ severity: "info" }]), 100);
  assert.equal(postureScore([{ severity: "low" }, { severity: "medium" }]), 95);
  assert.equal(postureScore([{ severity: "critical" }, { severity: "high" }]), 65);
  assert.equal(postureScore(Array(5).fill({ severity: "critical" })), 0, "the score floors at 0, it never goes negative");

  assert.equal(postureBand(100), "green");
  assert.equal(postureBand(85), "green");
  assert.equal(postureBand(84), "amber");
  assert.equal(postureBand(60), "amber");
  assert.equal(postureBand(59), "red");

  const counts = countBySeverity([{ severity: "low" }, { severity: "low" }, { severity: "high" }]);
  assert.equal(counts.low, 2);
  assert.equal(counts.high, 1);
  assert.equal(counts.critical, 0);
});
