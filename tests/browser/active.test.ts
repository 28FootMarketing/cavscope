// Group C: the tests that send data. Gate, matrix construction, and evaluation, with a fake endpoint.
//   node --experimental-strip-types --test tests/browser/active.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
// @ts-ignore
import * as a from "../../workers/browser-scan/lib/active.mjs";

const SITE = "aftertoday.example";
const opts = (over: Record<string, unknown> = {}) => ({ active_tests: true, authorization_id: 7, ...over });

test("GATE: active tests need a stored authorization, a verified site and an endpoint the authorization covers", () => {
  const ep = "https://api.aftertoday.example/submit";
  assert.equal(a.activeTestsPermitted({ options: opts(), verified: true, siteHost: SITE, endpointUrl: ep }).ok, true);
  assert.equal(a.activeTestsPermitted({ options: {}, verified: true, siteHost: SITE, endpointUrl: ep }).ok, false, "no authorization");
  assert.equal(a.activeTestsPermitted({ options: { active_tests: true }, verified: true, siteHost: SITE, endpointUrl: ep }).ok, false, "flag without a record id");
  assert.equal(a.activeTestsPermitted({ options: { active_tests: false, authorization_id: 7 }, verified: true, siteHost: SITE, endpointUrl: ep }).ok, false);
  assert.match(a.activeTestsPermitted({ options: opts(), verified: false, siteHost: SITE, endpointUrl: ep }).reason, /not verified/);
  assert.match(a.activeTestsPermitted({ options: opts(), verified: true, siteHost: SITE, endpointUrl: "http://api.aftertoday.example/submit" }).reason, /not HTTPS/);
  const other = a.activeTestsPermitted({ options: opts(), verified: true, siteHost: SITE, endpointUrl: "https://abc.supabase.co/functions/v1/contact" });
  assert.equal(other.ok, false, "someone else's service is not covered by the site owner's say-so");
  assert.match(other.reason, /abc\.supabase\.co.*not listed in the authorization/);
  assert.equal(a.activeTestsPermitted({ options: opts({ endpoint_hosts: ["abc.supabase.co"] }), verified: true, siteHost: SITE, endpointUrl: "https://abc.supabase.co/functions/v1/contact" }).ok, true, "unless the authorization names it");
});

const template = (body: Record<string, unknown>) => ({ url: "https://api.aftertoday.example/submit", method: "POST", contentType: "application/json", body: JSON.stringify(body) });
const body = { name: a.MARKER_NAME, email: a.MARKER_EMAIL, phone: a.MARKER_PHONE, service: "coaching", sms_consent: true, started_at: 1790000000000 };

test("MATRIX: seven cases from the form's own request, every value an obvious marker", () => {
  const cases = a.buildMatrix({ template: template(body), hiddenFields: ["website"], origin: "https://aftertoday.example" });
  assert.equal(cases.length, 7);
  assert.deepEqual(cases.map((c: any) => c.id), [1, 2, 3, 4, 5, 6, 7]);
  assert.ok(cases.every((c: any) => !c.notApplicable));
  const b = (n: number) => JSON.parse(cases[n - 1].request.body);
  assert.equal(b(1).name, "CAVSCOPE TEST (delete me)");
  assert.match(b(1).email, /@example\.com$/);
  assert.equal(b(2).service, "cavscope-invalid-option");
  assert.equal(b(3).phone, "");
  assert.equal(b(3).sms_consent, true);
  assert.equal(b(4).website, "cavscope-bot");
  assert.ok(b(5).started_at > Date.now() - 5000, "too-fast uses a timestamp from now");
  assert.equal(cases[5].request.headers.origin, a.DISALLOWED_ORIGIN);
  assert.equal(cases[6].request.method, "OPTIONS");
  assert.equal(cases[6].request.headers["access-control-request-method"], "POST");
  assert.ok(!("website" in b(1)), "the valid case never fills the honeypot");
});

test("MATRIX: cases that need a field the form does not have are marked not applicable, not invented", () => {
  const cases = a.buildMatrix({ template: template({ name: a.MARKER_NAME, email: a.MARKER_EMAIL }), hiddenFields: [], origin: "https://x.test" });
  assert.deepEqual(cases.filter((c: any) => c.notApplicable).map((c: any) => c.id), [2, 3, 4, 5]);
  assert.ok(cases.find((c: any) => c.id === 1).request && cases.find((c: any) => c.id === 6).request && cases.find((c: any) => c.id === 7).request);
  const multipart = a.buildMatrix({ template: { ...template(body), contentType: "multipart/form-data; boundary=x" }, hiddenFields: [], origin: "https://x.test" });
  assert.ok(multipart.every((c: any) => c.notApplicable), "a body that cannot be reshaped safely is not guessed at");
});

test("MATRIX: form-encoded bodies are reshaped as form-encoded", () => {
  const t = { url: "https://x.test/s", method: "POST", contentType: "application/x-www-form-urlencoded", body: "name=CAVSCOPE+TEST&service=a&email=cavscope-test%40example.com" };
  const cases = a.buildMatrix({ template: t, hiddenFields: [], origin: "https://x.test" });
  assert.match(cases[1].request.body, /service=cavscope-invalid-option/);
});

const origin = "https://aftertoday.example";
const fakeEndpoint = (over: Record<string, any> = {}) => async (_url: string, init: any) => {
  const o = init.headers.origin;
  const j = init.body ? JSON.parse(init.body) : {};
  const resp = (status: number, acao: string | null = null) => ({ status, headers: new Map([["access-control-allow-origin", acao], ["access-control-allow-credentials", null]]) as any });
  const R = (status: number, acao: string | null) => { const r: any = resp(status, acao); r.headers = { get: (k: string) => (k === "access-control-allow-origin" ? acao : null) }; return r; };
  if (init.method === "OPTIONS") return over.preflight ?? R(204, origin);
  if (o !== origin) return over.badOrigin ?? R(403, null);
  if (j.service === "cavscope-invalid-option") return over.invalid ?? R(400, origin);
  if (j.sms_consent && j.phone === "") return over.noPhone ?? R(400, origin);
  if (j.website) return over.honeypot ?? R(200, origin);
  return over.valid ?? R(200, origin);
};

test("EVALUATE: a well-built endpoint passes, with every status listed and the not-verified caveat stated", async () => {
  const cases = a.buildMatrix({ template: template({ ...body, started_at: 5 }), hiddenFields: ["website"], origin });
  const results = await a.runMatrix({ cases, fetchImpl: fakeEndpoint() });
  assert.deepEqual(results.map((r: any) => r.status), [200, 400, 400, 200, 200, 403, 204]);
  const ev = a.evaluateMatrix({ results, origin });
  assert.equal(ev.findings.length, 0);
  assert.equal(ev.checks[0].outcome, "passed");
  assert.match(ev.checks[0].detail, /whether a bot submission was stored cannot be seen from outside/);
});

test("EVALUATE: wildcard CORS, a 500, an echoed disallowed origin and accepted bad input are each reported", async () => {
  const cases = a.buildMatrix({ template: template({ ...body, started_at: 5 }), hiddenFields: ["website"], origin });
  const R = (status: number, acao: string | null) => ({ status, headers: { get: (k: string) => (k === "access-control-allow-origin" ? acao : null) } });
  const run = async (over: Record<string, any>) => a.evaluateMatrix({ results: await a.runMatrix({ cases, fetchImpl: fakeEndpoint(over) }), origin });
  assert.match((await run({ valid: R(200, "*") })).findings[0].detail, /wildcard/);
  assert.match((await run({ valid: R(500, origin) })).findings[0].detail, /server error 500/);
  assert.match((await run({ badOrigin: R(403, a.DISALLOWED_ORIGIN) })).findings[0].detail, /disallowed origin was echoed/);
  assert.match((await run({ invalid: R(200, origin) })).findings[0].detail, /Unknown option.*expected 400, got 200/);
  assert.match((await run({ badOrigin: R(200, null) })).findings[0].detail, /disallowed Origin: expected 401\/403, got 200/);
  assert.match((await run({ preflight: R(204, "https://other.test") })).findings[0].detail, /preflight did not allow the site's own origin/);
  const f = (await run({ valid: R(500, origin) })).findings[0];
  assert.equal(f.rule_id, "FORM-010");
  assert.match(f.detail, /CAVSCOPE TEST \(delete me\).*cavscope-test@example\.com/);
});

test("LIVE SUBMIT: success needs a success state AND a 2xx; delivery is never claimed; cleanup markers are listed", () => {
  const good = a.evaluateLiveSubmit({ res: { success: true, responses: [{ method: "POST", status: 200, url: "https://x/y" }], pageUrl: "https://x.test/contact" }, origin });
  assert.equal(good.checks[0].outcome, "passed");
  assert.match(good.checks[0].detail, /Delivery not verified: confirm the notification arrived/);
  assert.match(good.checks[0].detail, /CAVSCOPE TEST \(delete me\).*cavscope-test@example\.com.*5555550100/);
  const noMsg = a.evaluateLiveSubmit({ res: { success: false, responses: [{ method: "POST", status: 200 }] }, origin });
  assert.equal(noMsg.findings[0].severity, "high");
  assert.match(noMsg.findings[0].detail, /no success message appeared|showed no success state/);
  const bad = a.evaluateLiveSubmit({ res: { success: true, responses: [{ method: "POST", status: 500 }] }, origin });
  assert.match(bad.findings[0].detail, /endpoint answered 500/);
  const none = a.evaluateLiveSubmit({ res: { success: false, responses: [] }, origin });
  assert.match(none.findings[0].detail, /no request was sent/);
  assert.equal(a.evaluateLiveSubmit({ res: { error: "navigation timeout", responses: [] }, origin }).checks[0].outcome, "skipped");
});
