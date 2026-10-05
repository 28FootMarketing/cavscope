// The browser engine, end to end, against local fixture sites in real headless Chromium.
// Needs `npm install` in workers/browser-scan and a Chromium; skips (and says so) without them.
//   cd workers/browser-scan && npm install && cd ../.. && node --experimental-strip-types --test tests/browser/integration.test.ts
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { existsSync } from "node:fs";

let engine: any = null;
let fixtures: any = null;
let skip: string | false = false;
const scans: Record<string, any> = {};
const T = (name: string, fn: () => void) => test(name, (t) => { if (skip) return t.skip(String(skip)); fn(); });

before(async () => {
  try {
    engine = await import("../../workers/browser-scan/lib/engine.mjs");
    const { chromium } = await import("../../workers/browser-scan/node_modules/playwright-core/index.mjs");
    if (!existsSync(process.env.CHROMIUM_PATH || chromium.executablePath())) skip = "no Chromium installed";
  } catch (e) { skip = "browser engine dependencies are not installed (npm install in workers/browser-scan)"; }
  if (skip) { console.log("# skipping browser integration tests:", skip); return; }
  const { startFixtures } = await import("./fixture-server.mjs");
  fixtures = await startFixtures();
  for (const name of ["clean", "prechecked", "badaction", "scriptform", "scripthttp", "noalt", "ga", "cspbreak", "thirdparty"])
    scans[name] = await engine.runBrowserScan({ targetUrl: fixtures.url(name), cap: 5 });
});
after(async () => { if (fixtures) await fixtures.close(); });

const find = (name: string, rule: string, loc?: string) => scans[name].findings.filter((f: any) => f.rule_id === rule && (!loc || f.location.includes(loc)));
const checkOf = (name: string, rule: string) => scans[name].scan.browser_checks.find((c: any) => c.rule_id === rule);

T("the engine reports its version and visits the page", () => {
  assert.equal(engine.ENGINE_VERSION, "browser-1.0.0");
  assert.equal(scans.clean.scan.engine_version, "browser-1.0.0");
  assert.ok(scans.clean.scan.pages_visited >= 1);
});

T("CLEAN fixture: no axe violations, structure ok, no third parties, no cookies, no CSP breakage, inline script refused", () => {
  const s = scans.clean;
  assert.deepEqual(s.findings.filter((f: any) => ["A11Y-008", "A11Y-010", "TP-002", "PRIV-006", "SEC-021", "SEC-022", "FORM-001", "FORM-002", "FORM-003"].includes(f.rule_id)).map((f: any) => `${f.rule_id}:${f.location}`), []);
  for (const id of ["A11Y-008", "A11Y-010", "TP-002", "PRIV-006", "SEC-021", "SEC-022", "FORM-001", "FORM-002", "FORM-003"])
    assert.equal(checkOf("clean", id).outcome, "passed", `${id}: ${checkOf("clean", id)?.detail}`);
  assert.match(checkOf("clean", "TP-002").detail, /^0 third-party hosts/);
  assert.match(checkOf("clean", "PRIV-006").detail, /^0 cookies/);
  assert.match(checkOf("clean", "SEC-022").detail, /refused a harmless injected inline script/);
});

T("CLEAN fixture: axe ran under a strict CSP without the page's policy being bypassed", () => {
  const ev = scans.clean.evidence.find((e: any) => e.kind === "axe_results");
  assert.ok(ev, "axe evidence exists, so axe-core ran despite script-src 'self'");
  assert.match(ev.excerpt, /devtools_evaluate \(page CSP unchanged\)/);
  const probe = scans.clean.evidence.find((e: any) => e.kind === "csp_probe");
  assert.match(probe.excerpt, /"executed": false/);
  assert.match(probe.excerpt, /CSP was not bypassed or altered/);
});

T("CLEAN fixture: the gradient contrast case is settled from computed colours (gold on navy), not left open", () => {
  const ax = JSON.parse(scans.clean.evidence.find((e: any) => e.kind === "axe_results").excerpt);
  const resolved = ax.contrastResolved ?? [];
  assert.ok(resolved.length >= 1, "axe left the gradient text incomplete and CavScope resolved it");
  assert.ok(resolved.every((c: any) => c.status === "pass"), JSON.stringify(resolved));
  assert.ok(resolved[0].ratio >= 5.5, `ratio ${resolved[0].ratio}`);
  assert.equal(find("clean", "A11Y-009").length, 0, "nothing left to review");
});

T("evidence is hashed like the HTTP engine's: sha-256 hex of the full captured text", () => {
  for (const e of scans.clean.evidence) {
    assert.match(e.sha256, /^[0-9a-f]{64}$/, e.key);
    assert.ok(e.excerpt.length <= 8000);
    assert.ok(e.byte_length >= e.excerpt.length);
  }
  assert.equal(engine.sha256Hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
  const kinds = new Set(scans.clean.evidence.map((e: any) => e.kind));
  for (const k of ["browser_page", "axe_results", "request_list", "cookie_jar", "console_log", "form_inventory", "csp_probe", "dns_ns"]) assert.ok(kinds.has(k), k);
});

T("NEGATIVE: a pre-checked consent box produces FORM-002 naming that item", () => {
  const f = find("prechecked", "FORM-002");
  assert.equal(f.length, 1);
  assert.match(f[0].detail, /fail: Consent box is not pre-checked \(the consent box is checked by default\)/);
});

T("NEGATIVE: a form with action='#' produces FORM-001 at high severity", () => {
  const f = find("badaction", "FORM-001");
  assert.equal(f.length, 1);
  assert.equal(f[0].severity, "high");
  assert.match(f[0].detail, /goes nowhere/);
  assert.equal(f[0].confidence, "high", "it was submitted with the network blocked and no request was attempted");
  assert.match(f[0].detail, /no request to send the data was attempted/);
});

T("a form with action='#' that a script submits is observed, not guessed: HTTPS destination passes, plain http is high, and no data leaves", () => {
  const ok = scans.scriptform;
  assert.equal(find("scriptform", "FORM-001").length, 0, "the script posts to an https endpoint, so it is not a dead form");
  assert.match(checkOf("scriptform", "FORM-001").detail, /passed|submits over HTTPS to api\.example\.test/);
  assert.match(checkOf("scriptform", "FORM-001").detail, /submitted with the network blocked, so the destination was observed and nothing was sent/);
  const http = find("scripthttp", "FORM-001");
  assert.equal(http.length, 1);
  assert.equal(http[0].severity, "high");
  assert.match(http[0].detail, /POST to http:\/\/api\.example\.test\/submit.*blocked in the browser; nothing was sent/);
  // The observation request never left the browser: nothing here could have reached example.test.
  assert.ok(ok.evidence.some((e: any) => e.kind === "form_inventory"));
});

T("NEGATIVE: an image with no alt produces an axe violation and a structure finding", () => {
  const ax = find("noalt", "A11Y-008", "image-alt");
  assert.equal(ax.length, 1);
  assert.equal(ax[0].severity, "high", "axe marks image-alt critical");
  assert.equal(find("noalt", "A11Y-010", "alt").length, 1);
  assert.equal(checkOf("noalt", "A11Y-008").outcome, "finding");
});

T("NEGATIVE: a page that sets _ga on load produces PRIV-006, worded as observed", () => {
  const f = find("ga", "PRIV-006");
  assert.equal(f.length, 1);
  assert.equal(f[0].severity, "medium");
  assert.match(f[0].detail, /Observed before interaction.*_ga, _gid/);
  assert.doesNotMatch(f[0].detail, /session/, "a non-tracker cookie is not named as a tracker");
  const jar = JSON.parse(scans.ga.evidence.find((e: any) => e.kind === "cookie_jar").excerpt);
  assert.equal(jar.count, 3);
  assert.ok(jar.cookies.every((c: any) => !("value" in c)), "cookie values are never stored");
});

T("NEGATIVE: a CSP that blocks the page's own script produces SEC-021, and inline script is refused", () => {
  const f = find("cspbreak", "SEC-021", "csp-console");
  assert.equal(f.length, 1);
  assert.match(f[0].detail, /Refused to load the script/);
  assert.equal(checkOf("cspbreak", "SEC-022").outcome, "passed");
});

T("NEGATIVE: no CSP at all means the inline probe executes, reported as an info finding", () => {
  const f = find("noalt", "SEC-022");
  assert.equal(f.length, 1);
  assert.equal(f[0].severity, "info");
});

T("NEGATIVE: a request to another host is a TP-002 inventory entry", () => {
  const f = find("thirdparty", "TP-002");
  assert.equal(f.length, 1);
  assert.match(f[0].detail, /127\.0\.0\.1: 1 request \(image\)/);
});

T("active tests stay off and say so when not requested", () => {
  assert.equal(checkOf("clean", "FORM-010").outcome, "skipped");
  assert.match(checkOf("clean", "FORM-010").detail, /Not requested/);
  assert.equal(checkOf("clean", "FORM-011").outcome, "skipped");
});

T("every rule that applies has a check on a scan, so a clean scan still lists what passed", () => {
  const ids = scans.clean.scan.browser_checks.map((c: any) => c.rule_id);
  for (const id of ["A11Y-008", "A11Y-009", "A11Y-010", "TP-002", "PRIV-006", "SEC-021", "SEC-022", "FORM-001", "FORM-002", "FORM-003", "FORM-010", "FORM-011"]) assert.ok(ids.includes(id), id);
});
