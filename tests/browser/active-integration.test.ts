// Group C against a LOCAL endpoint over real HTTP: the seven-case matrix, a broken endpoint, and the live
// submit in Chromium. Never aimed at a live site. The engine's own gate (HTTPS + stored authorization) is
// covered in active.test.ts; here the pieces are called directly because the fixture is plain http.
//   node --experimental-strip-types --test tests/browser/active-integration.test.ts
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { existsSync } from "node:fs";

let a: any = null, collect: any = null, skip: string | false = false;
const servers: any[] = [];
const T = (name: string, fn: () => Promise<void>) => test(name, async (t) => { if (skip) return t.skip(String(skip)); await fn(); });

const stored: any[] = [];
function endpoint({ broken = false } = {}) {
  const srv = createServer((req, res) => {
    const origin = req.headers.origin as string | undefined;
    const allowed = origin && /^http:\/\/localhost:\d+$/.test(origin);
    const cors: Record<string, string> = broken ? { "access-control-allow-origin": "*" } : allowed ? { "access-control-allow-origin": origin! } : {};
    if (req.method === "OPTIONS") { res.writeHead(allowed || broken ? 204 : 403, { ...cors, "access-control-allow-methods": "POST", "access-control-allow-headers": "content-type" }); return res.end(); }
    let raw = ""; req.on("data", (c) => (raw += c)); req.on("end", () => {
      const send = (s: number, b: object = {}) => { res.writeHead(s, { ...cors, "content-type": "application/json" }); res.end(JSON.stringify(b)); };
      if (!allowed && !broken) return send(403, { error: "origin" });
      if (broken && req.headers.origin?.includes("disallowed")) return send(500, { error: "boom" });
      let j: any = {}; try { j = JSON.parse(raw); } catch { return send(400); }
      if (j.service === "cavscope-invalid-option") return send(broken ? 200 : 400);
      if (j.sms_consent && !j.phone) return send(400);
      if (j.website) return send(200, { ok: true });          // honeypot: silent
      if (Number(j.started_at) > Date.now() - 2000) return send(200, { ok: true }); // too fast: silent
      stored.push(j); send(200, { ok: true });
    });
  });
  return new Promise<{ url: string; srv: any }>((r) => srv.listen(0, "127.0.0.1", () => { servers.push(srv); r({ url: `http://127.0.0.1:${srv.address().port}/submit`, srv }); }));
}

before(async () => {
  try {
    a = await import("../../workers/browser-scan/lib/active.mjs");
    collect = await import("../../workers/browser-scan/lib/collect.mjs");
    const { chromium } = await import("../../workers/browser-scan/node_modules/playwright-core/index.mjs");
    if (!existsSync(process.env.CHROMIUM_PATH || chromium.executablePath())) skip = "no Chromium installed";
  } catch { skip = "browser engine dependencies are not installed"; }
});
after(() => { for (const s of servers) s.close(); });

const body = { name: "CAVSCOPE TEST (delete me)", email: "cavscope-test@example.com", phone: "5555550100", service: "coaching", sms_consent: true, started_at: 1790000000000 };
const tpl = (url: string) => ({ url, method: "POST", contentType: "application/json", body: JSON.stringify(body) });

T("a well-built endpoint answers the matrix as expected: 200, 400, 400, silent 200, silent 200, 403, CORS preflight with the site's origin", async () => {
  const { url } = await endpoint();
  const origin = "http://localhost:4321";
  const cases = a.buildMatrix({ template: tpl(url), hiddenFields: ["website"], origin });
  const results = await a.runMatrix({ cases, fetchImpl: fetch });
  assert.deepEqual(results.map((r: any) => r.status), [200, 400, 400, 200, 200, 403, 204]);
  assert.equal(results[0].acao, origin, "correct CORS origin on the real request");
  assert.equal(results[6].acao, origin, "and on the preflight");
  const ev = a.evaluateMatrix({ results, origin });
  assert.equal(ev.findings.length, 0, JSON.stringify(ev.findings));
  assert.equal(ev.checks[0].outcome, "passed");
  assert.equal(stored.length, 1, "exactly one test payload was stored: the valid one; the invalid, honeypot and too-fast cases stored nothing");
  assert.equal(stored[0].name, "CAVSCOPE TEST (delete me)");
});

T("a broken endpoint (wildcard CORS, a 500, accepts an unknown option) is reported with each deviation", async () => {
  const { url } = await endpoint({ broken: true });
  const origin = "http://localhost:4321";
  const results = await a.runMatrix({ cases: a.buildMatrix({ template: tpl(url), hiddenFields: ["website"], origin }), fetchImpl: fetch });
  const ev = a.evaluateMatrix({ results, origin });
  assert.equal(ev.findings.length, 1);
  assert.match(ev.findings[0].detail, /wildcard/);
  assert.match(ev.findings[0].detail, /server error 500/);
  assert.match(ev.findings[0].detail, /Unknown option.*expected 400, got 200/);
});

T("live submit: fills the real form with test data, waits the minimum fill time, and sees a success state and a 2xx", async () => {
  const { url } = await endpoint();
  const page = createServer((req, res) => {
    res.writeHead(200, { "content-type": "text/html" });
    res.end(`<!doctype html><html lang="en"><head><title>t</title></head><body><main><h1>Contact</h1>
      <form id="f" action="#"><label for="n">Name</label><input id="n" name="name" type="text"><label for="e">Email</label><input id="e" name="email" type="email">
      <input name="website" type="text" style="display:none"><button>Send</button><p id="msg" role="status"></p></form></main>
      <script>document.getElementById("f").addEventListener("submit",function(ev){ev.preventDefault();
        fetch(${JSON.stringify(url)},{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify({name:this.name.value,email:this.email.value,website:this.website.value,started_at:Date.now()-5000})})
        .then(function(r){ if(r.ok) document.getElementById("msg").textContent="Thank you, your message was sent."; });});</script></body></html>`);
  });
  await new Promise<void>((r) => page.listen(0, "127.0.0.1", r)); servers.push(page);
  const { chromium } = await import("../../workers/browser-scan/node_modules/playwright-core/index.mjs");
  const browser = await chromium.launch();
  try {
    const ctx = await collect.newScanContext(browser);
    const t0 = Date.now();
    const res = await collect.liveSubmit(ctx, `http://localhost:${(page.address() as any).port}/`, 0);
    assert.ok(Date.now() - t0 >= 3300, "waited at least the minimum fill time before submitting");
    assert.equal(res.success, true);
    assert.ok(res.responses.some((r: any) => r.method === "POST" && r.status === 200));
    const ev = a.evaluateLiveSubmit({ res, origin: "http://localhost" });
    assert.equal(ev.checks[0].outcome, "passed");
    assert.match(ev.checks[0].detail, /Delivery not verified/);
    assert.ok(stored.some((s) => s.name === "CAVSCOPE TEST (delete me)" && s.email === "cavscope-test@example.com" && !s.website), "the visible fields carried the markers and the honeypot stayed empty");
  } finally { await browser.close(); }
});
