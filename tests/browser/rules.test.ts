// Rule logic for the browser engine, on synthetic observations. Pure: no browser, no network.
//   node --experimental-strip-types --test tests/browser/rules.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
// @ts-ignore
import * as r from "../../workers/browser-scan/lib/rules.mjs";

const ORIGIN = "https://site.test";
const page = (over: Record<string, unknown> = {}) => ({
  url: ORIGIN + "/", finalUrl: ORIGIN + "/", evidenceKey: "page_1",
  structure: { title: "Home", h1Count: 1, lang: "en", imgTotal: 2, imgNoAlt: 0 },
  axe: { violations: [], incomplete: [] }, contrast: [], requests: [], console: [], forms: [], textSample: "", ...over,
});
const form = (over: Record<string, unknown> = {}) => ({ id: "contact", name: "", rawAction: "https://api.site.test/submit", action: "https://api.site.test/submit", method: "post", fields: [], links: [], nearText: "", hasPassword: false, hasPayment: false, ...over });
const fld = (over: Record<string, unknown> = {}) => ({ name: "", id: "", type: "text", required: false, checked: false, autocomplete: "", label: "", ...over });
const node = (html: string, target = ["img"]) => ({ target, html, failureSummary: "x", message: "x" });

test("A11Y-008: zero violations is recorded as a pass that says what ran, not as silence", () => {
  const { findings, checks } = r.evaluateAxe({ pages: [page(), page({ evidenceKey: "page_2", url: ORIGIN + "/a", finalUrl: ORIGIN + "/a" })], origin: ORIGIN, axeVersion: "4.13.0" });
  assert.equal(findings.length, 0);
  assert.equal(checks[0].rule_id, "A11Y-008");
  assert.equal(checks[0].outcome, "passed");
  assert.match(checks[0].detail, /0 violations on 2 of 2 pages/);
  assert.match(checks[0].detail, /only part of what a person would/);
  assert.doesNotMatch(checks[0].detail, /complian/i, "never claims compliance");
});

test("A11Y-008: one finding per axe rule per site, listing pages and node counts; impact maps to severity", () => {
  const v = (id: string, impact: string, n: number) => ({ id, impact, help: id + " help", helpUrl: "https://x/" + id, nodes: Array.from({ length: n }, () => node("<img src=a>")) });
  const p1 = page({ axe: { violations: [v("image-alt", "critical", 2), v("region", "moderate", 1)], incomplete: [] } });
  const p2 = page({ evidenceKey: "page_2", url: ORIGIN + "/a", finalUrl: ORIGIN + "/a", axe: { violations: [v("image-alt", "serious", 3), v("heading-order", "minor", 1)], incomplete: [] } });
  const { findings } = r.evaluateAxe({ pages: [p1, p2], origin: ORIGIN, axeVersion: "4.13.0" });
  const alt = findings.filter((f: any) => f.location === "image-alt");
  assert.equal(alt.length, 1, "one finding for image-alt across both pages");
  assert.equal(alt[0].severity, "high", "worst impact wins: critical -> high");
  assert.match(alt[0].detail, /2 pages \(5 elements\)/);
  assert.match(alt[0].detail, /\/ \(2\), \/a \(3\)/);
  assert.equal(findings.find((f: any) => f.location === "region").severity, "low");
  assert.equal(findings.find((f: any) => f.location === "heading-order").severity, "info");
  assert.ok(findings.every((f: any) => f.rule_id === "A11Y-008" && f.page_url === ORIGIN));
});

test("A11Y-009: incompletes are info 'needs review', never a pass or fail; resolved contrast splits into pass and fail", () => {
  const inc = { id: "aria-valid-attr-value", help: "ARIA attributes must have valid values", nodes: [node("<div aria-x>", ["div"])] };
  const contrast = [
    { target: ".a", status: "pass", ratio: 5.6, required: 4.5 },
    { target: ".b", status: "fail", ratio: 2.1, required: 4.5 },
    { target: ".c", status: "unresolved", reason: "background is an image", ratio: null },
  ];
  const { findings, checks } = r.evaluateAxe({ pages: [page({ axe: { violations: [], incomplete: [inc] }, contrast })], origin: ORIGIN, axeVersion: "4.13.0" });
  const review = findings.filter((f: any) => f.rule_id === "A11Y-009");
  assert.deepEqual(review.map((f: any) => f.location).sort(), ["aria-valid-attr-value", "color-contrast"]);
  assert.ok(review.every((f: any) => f.severity === "info" && /not a pass or a fail/.test(f.detail)));
  const fail = findings.find((f: any) => f.location === "color-contrast (resolved)");
  assert.equal(fail.rule_id, "A11Y-008", "a contrast case CavScope resolved as failing is a real finding");
  assert.match(fail.detail, /2\.1:1, needs 4\.5:1/);
  assert.equal(checks.find((c: any) => c.rule_id === "A11Y-009").outcome, "needs_review");
  assert.match(checks.find((c: any) => c.rule_id === "A11Y-009").detail, /1 contrast check resolved as passing.*1 as failing, 1 left for review/);
});

test("A11Y-009: contrast incompletes that all resolve to pass leave nothing to review", () => {
  const { findings, checks } = r.evaluateAxe({ pages: [page({ axe: { violations: [], incomplete: [{ id: "color-contrast", help: "c", nodes: [node("<p>")] }] }, contrast: [{ target: "p", status: "pass", ratio: 5.6, required: 4.5 }] })], origin: ORIGIN, axeVersion: "4.13.0" });
  assert.equal(findings.length, 0);
  assert.equal(checks[1].outcome, "passed");
});

test("A11Y-010: title, h1, lang and alt, each judged and each listed when it passes", () => {
  const good = r.evaluateStructure({ pages: [page()], origin: ORIGIN });
  assert.equal(good.findings.length, 0);
  assert.equal(good.checks[0].outcome, "passed");
  assert.match(good.checks[0].detail, /exactly one h1, a valid html lang, and 2 images all with an alt attribute/);
  const bad = r.evaluateStructure({ pages: [page({ structure: { title: "  ", h1Count: 2, lang: "", imgTotal: 3, imgNoAlt: 1 } })], origin: ORIGIN });
  assert.deepEqual(bad.findings.map((f: any) => f.location).sort(), ["alt", "h1", "lang", "title"]);
  assert.equal(r.evaluateStructure({ pages: [page({ structure: { title: "T", h1Count: 1, lang: "not a lang!", imgTotal: 0, imgNoAlt: 0 } })], origin: ORIGIN }).findings[0].location, "lang");
  assert.equal(r.evaluateStructure({ pages: [page({ structure: { title: "T", h1Count: 1, lang: "en-US", imgTotal: 0, imgNoAlt: 0 } })], origin: ORIGIN }).findings.length, 0);
});

test("TP-002: zero third-party hosts is a positive result and says so; a third party is listed with counts", () => {
  const reqs = [{ url: ORIGIN + "/a.js", host: "site.test", resourceType: "script" }, { url: ORIGIN + "/b.css", host: "cdn.site.test", resourceType: "stylesheet" }];
  const none = r.evaluateThirdParties({ pages: [page({ requests: reqs })], siteHost: "www.site.test", origin: ORIGIN });
  assert.equal(none.findings.length, 0);
  assert.equal(none.checks[0].outcome, "passed");
  assert.match(none.checks[0].detail, /^0 third-party hosts: all 2 requests/);
  const some = r.evaluateThirdParties({ pages: [page({ requests: [...reqs, { url: "https://fonts.gstatic.com/x", host: "fonts.gstatic.com", resourceType: "font" }, { url: "https://fonts.gstatic.com/y", host: "fonts.gstatic.com", resourceType: "font" }] })], siteHost: "site.test", origin: ORIGIN });
  assert.equal(some.findings.length, 1);
  assert.equal(some.findings[0].severity, "info");
  assert.match(some.findings[0].detail, /fonts\.gstatic\.com: 2 requests \(font\)/);
  assert.equal(some.inventory.hosts[0].count, 2);
});

test("PRIV-006: 0 cookies passes; a _ga cookie or a tracker host is observed-before-interaction, not a legal claim", () => {
  const zero = r.evaluateCookies({ firstLoad: { cookies: [], requests: [] }, siteHost: "site.test", origin: ORIGIN });
  assert.equal(zero.checks[0].outcome, "passed");
  assert.match(zero.checks[0].detail, /^0 cookies and 0 known tracker hosts observed before interaction/);
  const benign = r.evaluateCookies({ firstLoad: { cookies: [{ name: "session" }], requests: [] }, siteHost: "site.test", origin: ORIGIN });
  assert.equal(benign.findings.length, 0);
  assert.match(benign.checks[0].detail, /none match known advertising or analytics cookies/);
  const ga = r.evaluateCookies({ firstLoad: { cookies: [{ name: "_ga" }, { name: "_gid" }], requests: [] }, siteHost: "site.test", origin: ORIGIN });
  assert.equal(ga.findings[0].severity, "medium");
  assert.match(ga.findings[0].detail, /Observed before interaction/);
  assert.doesNotMatch(ga.findings[0].detail + ga.findings[0].title, /violat|illegal|unlawful/i);
  const host = r.evaluateCookies({ firstLoad: { cookies: [], requests: [{ host: "www.googletagmanager.com" }] }, siteHost: "site.test", origin: ORIGIN });
  assert.match(host.findings[0].detail, /googletagmanager/);
});

test("SEC-021: CSP console refusals and failed first-party requests are flagged; a third-party failure and an aborted request are not", () => {
  const clean = r.evaluateCspConsole({ pages: [page()], siteHost: "site.test", origin: ORIGIN });
  assert.equal(clean.checks[0].outcome, "passed");
  const p = page({
    console: [{ type: "error", text: "Refused to load the script 'https://x/y.js' because it violates the following Content Security Policy directive: script-src 'self'" }, { type: "log", text: "Content Security Policy is great" }],
    requests: [{ url: ORIGIN + "/missing.js", host: "site.test", failed: true, failureText: "net::ERR_CONNECTION_RESET" }, { url: ORIGIN + "/nav", host: "site.test", failed: true, aborted: true, failureText: "net::ERR_ABORTED" }, { url: "https://other.test/z", host: "other.test", failed: true, failureText: "x" }],
  });
  const f = r.evaluateCspConsole({ pages: [p], siteHost: "site.test", origin: ORIGIN }).findings;
  assert.deepEqual(f.map((x: any) => x.location).sort(), ["csp-console", "first-party-failed"]);
  assert.match(f.find((x: any) => x.location === "first-party-failed").detail, /1 request/);
  assert.equal(f.find((x: any) => x.location === "csp-console").detail.match(/1 browser console message/)?.length, 1, "an ordinary log line that mentions the words is not counted");
});

test("SEC-022: a refused inline script is a pass that says enforced; an executed one is an info finding", () => {
  const refused = r.evaluateCspProbe({ probe: { executed: false, violationEvent: true, page: "/" }, origin: ORIGIN });
  assert.equal(refused.checks[0].outcome, "passed");
  assert.match(refused.checks[0].detail, /refused a harmless injected inline script.*enforced/);
  const ran = r.evaluateCspProbe({ probe: { executed: true, violationEvent: false, page: "/" }, origin: ORIGIN });
  assert.equal(ran.findings[0].severity, "info");
  assert.equal(r.evaluateCspProbe({ probe: null, origin: ORIGIN }).checks[0].outcome, "not_applicable");
});

test("FORM-001: empty, # and javascript: actions are high, as is plain http; an https action passes with its host", () => {
  const mk = (rawAction: string | null, action: string, extra = {}) => page({ forms: [form({ rawAction, action, ...extra })] });
  for (const raw of ["#", "", null, "javascript:void(0)"]) {
    const res = r.evaluateForms001({ pages: [mk(raw as any, ORIGIN + "/")], origin: ORIGIN });
    assert.equal(res.findings[0].severity, "high", String(raw));
    assert.match(res.findings[0].detail, /goes nowhere/);
    assert.equal(res.findings[0].confidence, "medium", "a script may submit it: said so");
  }
  const http = r.evaluateForms001({ pages: [mk("http://x.test/p", "http://x.test/p", { hasPassword: true })], origin: ORIGIN });
  assert.equal(http.findings[0].severity, "high");
  assert.match(http.findings[0].detail, /password or payment/);
  const ok = r.evaluateForms001({ pages: [mk("https://abc.supabase.co/functions/v1/contact", "https://abc.supabase.co/functions/v1/contact")], origin: ORIGIN });
  assert.equal(ok.findings.length, 0);
  assert.match(ok.checks[0].detail, /1 form found; each submits over HTTPS to abc\.supabase\.co/);
  assert.equal(r.evaluateForms001({ pages: [page()], origin: ORIGIN }).checks[0].outcome, "not_applicable");
});

test("FORM-001: a script-submitted form is judged by the destination that was observed with the network blocked", () => {
  const obs = (url: string) => page({ forms: [form({ rawAction: "#", action: ORIGIN + "/", observed: { blocked: true, requests: [{ url, method: "POST" }] } })] });
  const good = r.evaluateForms001({ pages: [obs("https://abc.supabase.co/functions/v1/contact")], origin: ORIGIN });
  assert.equal(good.findings.length, 0);
  assert.match(good.checks[0].detail, /submits over HTTPS to abc\.supabase\.co \(1 through a script/);
  const bad = r.evaluateForms001({ pages: [obs("http://abc.test/x")], origin: ORIGIN });
  assert.equal(bad.findings[0].severity, "high");
  assert.match(bad.findings[0].detail, /not HTTPS/);
  const dead = r.evaluateForms001({ pages: [page({ forms: [form({ rawAction: "#", observed: { blocked: true, requests: [] } })] })], origin: ORIGIN });
  assert.equal(dead.findings[0].confidence, "high");
  const unobserved = r.evaluateForms001({ pages: [page({ forms: [form({ rawAction: "#" })] })], origin: ORIGIN });
  assert.equal(unobserved.findings[0].confidence, "medium");
});

const consentText = "By checking this box you agree to receive text messages. Message and data rates may apply. Message frequency varies. Reply STOP to cancel or HELP for help. Consent is not a condition of purchase.";
const goodSms = (over: Record<string, unknown> = {}) => page({ forms: [form({
  fields: [fld({ name: "phone", type: "tel" }), fld({ name: "sms_consent", type: "checkbox", label: "I agree to receive text messages", checked: false })],
  nearText: consentText, links: [{ text: "Privacy Policy", href: ORIGIN + "/privacy" }, { text: "SMS Terms", href: ORIGIN + "/sms-terms" }], ...over })] });
const ok200 = async () => 200;

test("FORM-002: a complete consent block passes all nine items", async () => {
  const res = await r.evaluateSmsConsent({ pages: [goodSms()], origin: ORIGIN, fetchStatus: ok200 });
  assert.equal(res.findings.length, 0);
  assert.equal(res.checks[0].outcome, "passed");
  assert.match(res.checks[0].detail, /all nine readiness checks passed.*not legal advice/);
});

test("FORM-002: each missing item fails by name: pre-checked, no STOP, no HELP, no rates, no frequency, dead links, no condition statement", async () => {
  const run = async (over: Record<string, unknown>, fetchStatus = ok200) => (await r.evaluateSmsConsent({ pages: [goodSms(over)], origin: ORIGIN, fetchStatus })).findings[0]?.detail ?? "";
  const checked = goodSms(); (checked.forms[0].fields[1] as any).checked = true;
  assert.match((await r.evaluateSmsConsent({ pages: [checked], origin: ORIGIN, fetchStatus: ok200 })).findings[0].detail, /fail: Consent box is not pre-checked/);
  assert.match(await run({ nearText: consentText.replace(/STOP/g, "quit") }), /fail: Mentions STOP/);
  assert.match(await run({ nearText: consentText.replace(" or HELP for help", "") }), /fail: Mentions HELP/);
  assert.match(await run({ nearText: consentText.replace(/Message and data rates may apply\./, "") }), /fail: Mentions message and data rates/);
  assert.match(await run({ nearText: consentText.replace(/Message frequency varies\./, "") }), /fail: Mentions message frequency/);
  assert.match(await run({ nearText: consentText.replace(/Consent is not a condition of purchase\./, "") }), /fail: States consent is not a condition of purchase/);
  assert.match(await run({}, async (u: string) => (u.includes("privacy") ? 404 : 200)), /fail: Links to a Privacy Policy that returns HTTP 200 \(.*privacy returned 404\)/);
  assert.match(await run({ links: [] }), /no privacy policy link near the consent text/);
  const reqPhone = goodSms(); (reqPhone.forms[0].fields[0] as any).required = true;
  assert.match((await r.evaluateSmsConsent({ pages: [reqPhone], origin: ORIGIN, fetchStatus: ok200 })).findings[0].detail, /fail: Phone is not required unless consent is/);
  const none = await r.evaluateSmsConsent({ pages: [goodSms({ fields: [fld({ name: "phone", type: "tel" })] })], origin: ORIGIN, fetchStatus: ok200 });
  assert.match(none.findings[0].detail, /no consent checkbox found/);
});

test("FORM-002: not applicable without a phone field or consent box", async () => {
  const res = await r.evaluateSmsConsent({ pages: [page({ forms: [form({ fields: [fld({ name: "email", type: "email" })] })] })], origin: ORIGIN, fetchStatus: ok200 });
  assert.equal(res.checks[0].outcome, "not_applicable");
});

test("FORM-003: a youth-facing page with a personal-data form and no notice gets an info prompt, worded as a prompt", () => {
  const f = form({ fields: [fld({ name: "email", type: "email" })], nearText: "Join our team" });
  const bad = r.evaluateMinors({ pages: [page({ forms: [f], textSample: "Youth athletes and their parents" })], origin: ORIGIN });
  assert.equal(bad.findings[0].severity, "info");
  assert.match(bad.findings[0].detail, /Consider adding one.*not a legal conclusion/);
  const withNotice = r.evaluateMinors({ pages: [page({ forms: [form({ ...f, nearText: "Under 18? A parent or guardian must complete this form." })], textSample: "Youth athletes" })], origin: ORIGIN });
  assert.equal(withNotice.findings.length, 0);
  assert.equal(withNotice.checks[0].outcome, "passed");
  assert.equal(r.evaluateMinors({ pages: [page({ forms: [f], textSample: "We sell plumbing supplies" })], origin: ORIGIN }).checks[0].outcome, "not_applicable");
});

test("every rule that ran has a check, so a clean scan lists what passed", () => {
  const pages = [page()];
  const all = [
    r.evaluateAxe({ pages, origin: ORIGIN }), r.evaluateStructure({ pages, origin: ORIGIN }),
    r.evaluateThirdParties({ pages, siteHost: "site.test", origin: ORIGIN }),
    r.evaluateCookies({ firstLoad: { cookies: [], requests: [] }, siteHost: "site.test", origin: ORIGIN }),
    r.evaluateCspConsole({ pages, siteHost: "site.test", origin: ORIGIN }),
    r.evaluateCspProbe({ probe: { executed: false, page: "/" }, origin: ORIGIN }),
    r.evaluateForms001({ pages, origin: ORIGIN }), r.evaluateMinors({ pages, origin: ORIGIN }),
  ].flatMap((x: any) => x.checks).map((c: any) => c.rule_id).sort();
  assert.deepEqual(all, ["A11Y-008", "A11Y-009", "A11Y-010", "FORM-001", "FORM-003", "PRIV-006", "SEC-021", "SEC-022", "TP-002"]);
});

// @ts-ignore
import { confirmFailedRequests } from "../../workers/browser-scan/lib/confirm.mjs";

test("a failed first-party request that answers over plain HTTP is transient and is NOT reported; one that still fails is", async () => {
  const mk = () => page({ requests: [
    { url: ORIGIN + "/ok.png", host: "site.test", failed: true, failureText: "net::ERR_TOO_MANY_RETRIES" },
    { url: ORIGIN + "/gone.js", host: "site.test", failed: true, failureText: "net::ERR_CONNECTION_RESET" },
    { url: ORIGIN + "/nav", host: "site.test", failed: true, aborted: true },
    { url: "https://other.test/x", host: "other.test", failed: true, failureText: "x" },
  ] });
  const p = mk();
  const checked = await confirmFailedRequests({ pages: [p], siteHost: "site.test", fetchStatus: async (u: string) => (u.endsWith("ok.png") ? 200 : 404) });
  assert.equal(checked, 2, "only first-party, non-aborted failures are re-checked");
  assert.equal(p.requests[0].transient, true);
  assert.equal(p.requests[1].transient, undefined);
  const res = r.evaluateCspConsole({ pages: [p], siteHost: "site.test", origin: ORIGIN }).findings;
  assert.equal(res.length, 1);
  assert.match(res[0].detail, /gone\.js/);
  assert.doesNotMatch(res[0].detail, /ok\.png/);
  const none = await confirmFailedRequests({ pages: [mk()], siteHost: "site.test", fetchStatus: async () => null });
  assert.equal(none, 2, "an unreachable check leaves the failure standing");
});

test("A11Y-008: a finding from a page that lost its own files while loading is low confidence and says to rescan", () => {
  const v = [{ id: "target-size", impact: "serious", help: "Targets must be big enough", helpUrl: "u", nodes: [node("<a>x</a>", ["a"])] }];
  const ok = r.evaluateAxe({ pages: [page({ axe: { violations: v, incomplete: [] } })], origin: ORIGIN, axeVersion: "4.13.0" }).findings[0];
  assert.equal(ok.confidence, "high");
  const bad = r.evaluateAxe({ pages: [page({ degraded: true, axe: { violations: v, incomplete: [] } })], origin: ORIGIN, axeVersion: "4.13.0" }).findings[0];
  assert.equal(bad.confidence, "low");
  assert.match(bad.detail, /lost some of its own files while loading.*rescan to confirm/);
});
