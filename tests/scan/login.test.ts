// AUTH-001..005: the login surface, read from outside.
//
//   node --experimental-strip-types --test tests/scan/login.test.ts
//
// These rules accuse a client's login page of something on the strength of one
// anonymous GET. The expensive failure is the false accusation: calling a
// single-page app's catch-all route "phpMyAdmin", judging a vendor's portal as
// if the client ran it, or scoring a homepage login form twice. Most of what
// follows guards that direction.
//
// This file also owns the ENGINE_VERSION equality pin (CLAUDE.md: the newest
// rule's test owns it); availability.test.ts now asserts a floor.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import {
  ADMIN_PROBES, evaluateAdminProbes, evaluateLoginPage, findLoginLinks, hasPasswordField,
  isSameSite, passwordForms, probeHit, type ProbeResult,
} from "../../supabase/functions/muster-scan/login.ts";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const engine = readFileSync(join(repoRoot, "supabase", "functions", "muster-scan", "index.ts"), "utf8");
const loginSrc = readFileSync(join(repoRoot, "supabase", "functions", "muster-scan", "login.ts"), "utf8");

const HOME = "https://www.example.com/";
const HOST = "www.example.com";
const FORM = `<form method="post" action="/session"><input name="u"><input type="password" name="p"></form>`;
const SAFE_HEADERS = { "x-frame-options": "DENY" };
// A homepage that is HTTPS, refuses framing and set no bad cookies: every
// AUTH-* defect below is then worse than the homepage, so it is AUTH-*'s to raise.
const HARDENED_HOME = { https: true, frameProtected: true, flaggedCookies: [] as string[] };

// --- scope -----------------------------------------------------------------

test("same site means the host or a subdomain of it, www set aside", () => {
  assert.ok(isSameSite("www.example.com", HOST));
  assert.ok(isSameSite("example.com", HOST));
  assert.ok(isSameSite("portal.example.com", HOST));
  assert.ok(isSameSite("PORTAL.EXAMPLE.COM.", HOST));
  // A vendor's portal is the vendor's login page, not the client's.
  assert.ok(!isSameSite("example.powerschool.com", HOST));
  // A lookalike that merely contains the name must never count.
  assert.ok(!isSameSite("example.com.evil.net", HOST));
  assert.ok(!isSameSite("notexample.com", HOST));
});

// --- discovery -------------------------------------------------------------

test("findLoginLinks finds sign-in links by text or by path, on-site only", () => {
  const html = `
    <a href="/login">Members</a>
    <a href="/about">Sign in</a>
    <a href="https://portal.example.com/">Client Portal</a>
    <a href="https://example.powerschool.com/public/">Parent Portal</a>
    <a href="/pricing">Pricing</a>`;
  const { onSite, offSite } = findLoginLinks(html, HOME, HOST, 5);
  assert.deepEqual(onSite, [
    "https://www.example.com/login",
    "https://www.example.com/about",
    "https://portal.example.com/",
  ]);
  assert.deepEqual(offSite, ["https://example.powerschool.com/public/"]);
});

test("findLoginLinks skips logout, sign-up, reset, anchors and script links", () => {
  const html = `
    <a href="/logout">Log out</a>
    <a href="/signup">Sign up</a>
    <a href="/account/register">Create account</a>
    <a href="/forgot-password">Forgot your login?</a>
    <a href="#login">Log in</a>
    <a href="javascript:openLogin()">Log in</a>
    <a href="mailto:login@example.com">Login help</a>`;
  assert.deepEqual(findLoginLinks(html, HOME, HOST), { onSite: [], offSite: [] });
});

test("findLoginLinks ignores the query string and does not read 'accounts' as 'account'", () => {
  const html = `
    <a href="/blog?utm_source=login">Blog</a>
    <a href="/accounts-payable">Accounts payable</a>`;
  assert.deepEqual(findLoginLinks(html, HOME, HOST).onSite, []);
});

test("findLoginLinks deduplicates, drops the page itself, and honours the cap", () => {
  const html = `
    <a href="/login">Log in</a><a href="/login#top">Login</a>
    <a href="/">Sign in</a>
    <a href="/a/login">x</a><a href="/b/login">x</a><a href="/c/login">x</a>`;
  const { onSite } = findLoginLinks(html, HOME, HOST, 3);
  assert.deepEqual(onSite, [
    "https://www.example.com/login",
    "https://www.example.com/a/login",
    "https://www.example.com/b/login",
  ]);
});

// --- reading a login page --------------------------------------------------

test("a password field is recognised in any quoting, and nothing else is", () => {
  assert.ok(hasPasswordField(`<input type="password">`));
  assert.ok(hasPasswordField(`<input name=p type=password>`));
  assert.ok(hasPasswordField(`<INPUT TYPE='PASSWORD'/>`));
  assert.ok(!hasPasswordField(`<input type="text" name="password">`));
  assert.ok(!hasPasswordField(`<p>Enter your password</p>`));
});

test("passwordForms resolves the action, and an empty action posts to the page", () => {
  const html = `
    <form action="/search"><input name=q></form>
    <form action=""><input type=password></form>
    <form action="http://www.example.com/auth"><input type="password"></form>`;
  const forms = passwordForms(html, "https://www.example.com/login");
  assert.deepEqual(forms.map((f) => f.action), [
    "https://www.example.com/login",
    "http://www.example.com/auth",
  ]);
});

test("a page with no password field in its HTML raises nothing", () => {
  // A JavaScript-rendered form, or an SSO button, is not a form the engine saw.
  const out = evaluateLoginPage({ url: "http://www.example.com/login", headers: {}, setCookies: ["s=1"],
    html: `<div id="root"></div><a href="https://login.microsoftonline.com/">Sign in with Microsoft</a>`, evidenceKey: "login_1", homepage: HARDENED_HOME });
  assert.deepEqual(out, []);
});

test("a hardened HTTPS login page raises nothing", () => {
  const out = evaluateLoginPage({ url: "https://www.example.com/login", headers: SAFE_HEADERS,
    setCookies: ["sid=abc; Path=/; Secure; HttpOnly; SameSite=Lax"], html: FORM, evidenceKey: "login_1", homepage: HARDENED_HOME });
  assert.deepEqual(out, []);
});

test("AUTH-001: an HTTPS site whose login page is served over HTTP", () => {
  const out = evaluateLoginPage({ url: "http://www.example.com/login", headers: SAFE_HEADERS, setCookies: [], html: FORM, evidenceKey: "login_1", homepage: HARDENED_HOME });
  assert.equal(out.length, 1);
  assert.equal(out[0].rule_id, "AUTH-001");
  assert.equal(out[0].severity, "high");
  assert.equal(out[0].page_url, "http://www.example.com/login");
  assert.deepEqual(out[0].evidence_keys, ["login_1"]);
});

test("AUTH-001: an HTTPS page whose password form posts to HTTP", () => {
  const html = `<form action="http://www.example.com/auth"><input type=password></form>`;
  const out = evaluateLoginPage({ url: "https://www.example.com/login", headers: SAFE_HEADERS, setCookies: [], html, evidenceKey: "k", homepage: HARDENED_HOME });
  assert.deepEqual(out.map((f) => f.rule_id), ["AUTH-001"]);
  assert.match(out[0].detail, /http:\/\/www\.example\.com\/auth/);
});

test("AUTH-002: framing is judged from headers only, never from a <meta> CSP", () => {
  const meta = `<meta http-equiv="Content-Security-Policy" content="frame-ancestors 'none'">` + FORM;
  const bare = evaluateLoginPage({ url: "https://www.example.com/login", headers: {}, setCookies: [], html: meta, evidenceKey: "k", homepage: HARDENED_HOME });
  assert.deepEqual(bare.map((f) => f.rule_id), ["AUTH-002"]);
  const csp = evaluateLoginPage({ url: "https://www.example.com/login", headers: { "content-security-policy": "frame-ancestors 'self'" }, setCookies: [], html: FORM, evidenceKey: "k", homepage: HARDENED_HOME });
  assert.deepEqual(csp, []);
});

test("AUTH-003: names each cookie and what it lacks, and exempts CSRF tokens from HttpOnly only", () => {
  const out = evaluateLoginPage({ url: "https://www.example.com/login", headers: SAFE_HEADERS, html: FORM, evidenceKey: "k", homepage: HARDENED_HOME,
    setCookies: [
      "PHPSESSID=1; path=/",
      "XSRF-TOKEN=2; Secure; SameSite=Lax",
      "csrftoken=3; path=/",
      "ok=4; Secure; HttpOnly; SameSite=Strict",
    ] });
  assert.deepEqual(out.map((f) => f.rule_id), ["AUTH-003"]);
  assert.match(out[0].detail, /PHPSESSID: missing Secure, HttpOnly, SameSite/);
  // Readable by script on purpose, so only the other flags are asked for.
  assert.doesNotMatch(out[0].detail, /XSRF-TOKEN: missing/);
  assert.match(out[0].detail, /csrftoken: missing Secure, SameSite/);
  assert.doesNotMatch(out[0].detail, /ok: missing/);
});

test("AUTH-003 skips wordpress_test_cookie, verbatim from its first live firing, and nothing else", () => {
  // Scan 86, www.hanoverymca.org/login/, 2026-09-23. The constant value is the
  // point: it carries no identity, so its flags protect nothing.
  const out = evaluateLoginPage({ url: "https://www.hanoverymca.org/login/", headers: SAFE_HEADERS, html: FORM, evidenceKey: "k", homepage: HARDENED_HOME,
    setCookies: ["wordpress_test_cookie=WP%20Cookie%20check; path=/; secure"] });
  assert.deepEqual(out, []);
  // An exact name, not a pattern: a real WordPress session cookie beside it
  // is still judged, and so is a lookalike.
  const mixed = evaluateLoginPage({ url: "https://www.hanoverymca.org/login/", headers: SAFE_HEADERS, html: FORM, evidenceKey: "k", homepage: HARDENED_HOME,
    setCookies: [
      "wordpress_test_cookie=WP%20Cookie%20check; path=/; secure",
      "wordpress_logged_in_abc=1; path=/; secure",
      "wordpress_test_cookie2=x; path=/",
    ] });
  assert.deepEqual(mixed.map((f) => f.rule_id), ["AUTH-003"]);
  assert.doesNotMatch(mixed[0].detail, /wordpress_test_cookie:/);
  assert.match(mixed[0].detail, /wordpress_logged_in_abc: missing HttpOnly, SameSite/);
  assert.match(mixed[0].detail, /wordpress_test_cookie2: missing Secure, HttpOnly, SameSite/);
});

test("AUTH-003 does not ask for Secure on an HTTP page, where AUTH-001 already owns the defect", () => {
  const out = evaluateLoginPage({ url: "http://www.example.com/login", headers: SAFE_HEADERS, html: FORM, evidenceKey: "k", homepage: HARDENED_HOME,
    setCookies: ["sid=1; HttpOnly; SameSite=Lax"] });
  assert.deepEqual(out.map((f) => f.rule_id), ["AUTH-001"]);
});

// --- one defect is scored once ------------------------------------------------

test("an HTTP-only site is SEC-013's: its HTTP login page is not raised again as AUTH-001", () => {
  const home = { https: false, frameProtected: true, flaggedCookies: [] };
  const out = evaluateLoginPage({ url: "http://www.example.com/login", headers: SAFE_HEADERS, setCookies: [], html: FORM, evidenceKey: "k", homepage: home });
  assert.deepEqual(out, []);
});

test("an insecure form action is AUTH-001's even on an HTTP site, because PRIV-003 reads only the homepage", () => {
  const home = { https: false, frameProtected: true, flaggedCookies: [] };
  const html = `<form action="http://auth.example.net/login"><input type=password></form>`;
  const out = evaluateLoginPage({ url: "http://www.example.com/login", headers: SAFE_HEADERS, setCookies: [], html, evidenceKey: "k", homepage: home });
  assert.deepEqual(out.map((f) => f.rule_id), ["AUTH-001"]);
  assert.match(out[0].detail, /submit to plain HTTP/);
});

test("a site with no framing protection anywhere is SEC-005's, not AUTH-002's", () => {
  const home = { https: true, frameProtected: false, flaggedCookies: [] };
  const out = evaluateLoginPage({ url: "https://www.example.com/login", headers: {}, setCookies: [], html: FORM, evidenceKey: "k", homepage: home });
  assert.deepEqual(out, []);
});

test("a cookie SEC-011 already reported on the homepage is not reported again by AUTH-003", () => {
  const home = { https: true, frameProtected: true, flaggedCookies: ["PHPSESSID"] };
  const out = evaluateLoginPage({ url: "https://www.example.com/login", headers: SAFE_HEADERS, html: FORM, evidenceKey: "k", homepage: home,
    setCookies: ["phpsessid=1; path=/", "login_token=2; path=/"] });
  assert.deepEqual(out.map((f) => f.rule_id), ["AUTH-003"]);
  assert.doesNotMatch(out[0].detail, /phpsessid/i);
  assert.match(out[0].detail, /login_token: missing Secure, HttpOnly, SameSite/);
});

test("the engine derives the homepage baseline from the same conditions SEC-005 and SEC-011 use", () => {
  const section = engine.slice(engine.indexOf("// 5b. The login surface"), engine.indexOf("// 6. Email authentication"));
  assert.match(section, /https: isHttps/);
  assert.match(section, /frameProtected: !frameable\(primary\.headers\)/);
  // SEC-011's own filter, character for character, so the two cannot disagree
  // about which homepage cookies were reported.
  const sec011 = engine.match(/const badCookies = primary\.setCookies\.filter\((.*?)\);\n/)?.[1];
  assert.ok(sec011, "SEC-011's cookie filter moved; update this test");
  assert.ok(section.includes(`.filter(${sec011.replace(/\\/g, "\\\\")})`) || section.includes(`.filter(${sec011})`),
    "the AUTH-003 baseline filter no longer matches SEC-011's");
});

// --- admin probes ----------------------------------------------------------

const probe = (path: string) => ADMIN_PROBES.find((p) => p.path === path)!;
const result = (path: string, body: string, status: number | null = 200, finalUrl: string | null = "https://www.example.com" + path): ProbeResult =>
  ({ probe: probe(path), finalUrl, status, body });

const WP = `<form name="loginform" action="https://www.example.com/wp-login.php" method="post"><input name="log"><input type="password" name="pwd"></form>`;
const PMA = `<title>phpMyAdmin</title><form><input name="pma_username" id="input_username"><input type="password" name="pma_password"></form>`;
const SPA_SHELL = `<!doctype html><html><head><title>Example</title></head><body><div id="root"></div></body></html>`;

test("the probes are plain GET paths and there are five of them", () => {
  assert.deepEqual(ADMIN_PROBES.map((p) => p.path), ["/wp-login.php", "/administrator/", "/user/login", "/phpmyadmin/", "/adminer.php"]);
});

test("a catch-all 200 is never a hit: a status code proves nothing without the product's own form", () => {
  // The single most important negative. A single-page app answers every path
  // with its shell, and reading that as "phpMyAdmin is exposed" would be a high
  // finding against a site that does not run it.
  for (const p of ADMIN_PROBES) {
    assert.equal(probeHit(result(p.path, SPA_SHELL)), false, p.path);
    assert.equal(probeHit(result(p.path, `<form><input type=password></form>`)), false, `${p.path} with a generic login`);
  }
  assert.deepEqual(evaluateAdminProbes({ results: ADMIN_PROBES.map((p) => result(p.path, SPA_SHELL)), evidenceKey: "d" }), []);
});

test("a probe that left the site, or did not answer 200, is not a hit", () => {
  assert.equal(probeHit(result("/phpmyadmin/", PMA, 200, null)), false);
  assert.equal(probeHit(result("/phpmyadmin/", PMA, 403)), false);
  assert.equal(probeHit(result("/phpmyadmin/", PMA, null)), false);
});

test("AUTH-004: a CMS login at its default path is low, and says MFA is unseen rather than absent", () => {
  const out = evaluateAdminProbes({ results: [result("/wp-login.php", WP)], evidenceKey: "login_discovery" });
  assert.equal(out.length, 1);
  assert.equal(out[0].rule_id, "AUTH-004");
  assert.equal(out[0].severity, "low");
  assert.match(out[0].detail, /not a vulnerability on its own/);
  assert.match(out[0].detail, /cannot see whether multi-factor authentication/);
  assert.deepEqual(out[0].evidence_keys, ["login_discovery"]);
});

test("AUTH-005: a database console is high", () => {
  const out = evaluateAdminProbes({ results: [result("/phpmyadmin/", PMA), result("/adminer.php", `<h1>Adminer</h1><input name="auth[username]">`)], evidenceKey: "d" });
  assert.deepEqual(out.map((f) => [f.rule_id, f.severity]), [["AUTH-005", "high"], ["AUTH-005", "high"]]);
  // Two consoles, two locations, so two fingerprints rather than one.
  assert.deepEqual(out.map((f) => f.location), ["/phpmyadmin/", "/adminer.php"]);
});

// --- what it must never do -------------------------------------------------

test("the login module sends nothing: no fetch, no POST, no credential", () => {
  // login.ts is pure. The only network calls in this feature are index.ts's
  // GETs through followChain; a fetch or a POST appearing here would mean the
  // engine had started submitting forms.
  assert.doesNotMatch(loginSrc, /\bfetch\s*\(/);
  assert.doesNotMatch(loginSrc, /method\s*:\s*["']POST/i);
});

test("the engine's login section only follows chains, which are GET", () => {
  const start = engine.indexOf("// 5b. The login surface");
  const end = engine.indexOf("// 6. Email authentication");
  assert.ok(start > 0 && end > start);
  const section = engine.slice(start, end);
  assert.doesNotMatch(section, /"POST"|"HEAD"/);
  assert.match(section, /followChain\(u, LOGIN_HOPS, LOGIN_TIMEOUT_MS\)/);
  assert.match(section, /followChain\(origin \+ p\.path, LOGIN_HOPS, LOGIN_TIMEOUT_MS\)/);
  // The homepage is SEC-*'s, never AUTH-*'s.
  assert.match(section, /url === homeKey/);
  // Evidence kind must be one scan_evidence's CHECK accepts, or ingest fails
  // and the whole scan with it.
  assert.match(section, /key: "login_discovery", kind: "http_probe"/);
});

test("the engine version moved with the rule set", () => {
  // A finding's severity is only comparable across scans on the same version.
  assert.match(engine, /const ENGINE_VERSION = "http-native-1\.8\.0";/);
  assert.match(engine, /1\.7\.0 adds AUTH-001\.\.005/);
  assert.match(engine, /1\.7\.1 stops AUTH-003 reporting wordpress_test_cookie/);
});
