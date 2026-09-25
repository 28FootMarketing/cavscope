// Routing middleware: host/path resolution and the security headers.
//
//   node --experimental-strip-types --test tests/routing/middleware.test.ts
//
// This imports the shipped middleware.js and calls it with real Request
// objects. rewrite() and next() from @vercel/functions are pure -- they return
// a Response carrying x-middleware-rewrite / x-middleware-next plus whatever
// headers were passed in -- so the routing table and the headers are both
// checkable here rather than only in production.

import { test } from "node:test";
import assert from "node:assert/strict";

import middleware from "../../middleware.js";

const call = (url: string, host: string): Response =>
  middleware(new Request(url, { headers: { host } })) as Response;

/** The path the middleware rewrote to, or null when it passed through. */
function rewriteTarget(res: Response): string | null {
  const to = res.headers.get("x-middleware-rewrite");
  return to ? new URL(to, "https://example.invalid").pathname : null;
}

const SECURITY_HEADERS = [
  "content-security-policy",
  "x-frame-options",
  "x-content-type-options",
  "referrer-policy",
  "permissions-policy",
];

// Every response, on every host, including the pass-throughs. A branch that
// forgets them is the failure this catches.
const EVERY_ROUTE: Array<[string, string]> = [
  ["https://muster.partners/", "muster.partners"],
  ["https://www.muster.partners/", "www.muster.partners"],
  ["https://muster.partners/privacy", "muster.partners"],
  ["https://muster.partners/onboarding", "muster.partners"],
  ["https://muster.partners/sitrep", "muster.partners"],
  ["https://muster.partners/sitrep/sample", "muster.partners"],
  ["https://muster.partners/robots.txt", "muster.partners"],
  ["https://muster.partners/sitemap.xml", "muster.partners"],
  ["https://muster.partners/.well-known/security.txt", "muster.partners"],
  ["https://muster.partners/assets/favicon-32.png", "muster.partners"],
  ["https://app.muster.partners/", "app.muster.partners"],
  ["https://app.muster.partners/app", "app.muster.partners"],
  ["https://app.muster.partners/signin", "app.muster.partners"],
  ["https://app.muster.partners/admin", "app.muster.partners"],
  ["https://app.muster.partners/reset", "app.muster.partners"],
  ["https://app.muster.partners/robots.txt", "app.muster.partners"],
  ["https://app.muster.28footsystems.com/app", "app.muster.28footsystems.com"],
  ["https://onboarding.muster.28footsystems.com/", "onboarding.muster.28footsystems.com"],
  ["https://sitrep.muster.28footsystems.com/", "sitrep.muster.28footsystems.com"],
  ["https://sitrep.muster.28footsystems.com/sample", "sitrep.muster.28footsystems.com"],
  ["https://muster.28footsystems.com/", "muster.28footsystems.com"],
];

test("every route carries every security header", () => {
  for (const [url, host] of EVERY_ROUTE) {
    const res = call(url, host);
    for (const h of SECURITY_HEADERS) {
      assert.ok(res.headers.get(h), `${h} missing on ${host}${new URL(url).pathname}`);
    }
  }
});

test("the CSP allows exactly the origins the pages actually load", () => {
  const csp = call("https://muster.partners/", "muster.partners").headers.get("content-security-policy")!;
  // Present because the pages demonstrably use them.
  assert.match(csp, /script-src[^;]*https:\/\/cdn\.jsdelivr\.net/);
  assert.match(csp, /style-src[^;]*https:\/\/fonts\.googleapis\.com/);
  assert.match(csp, /font-src[^;]*https:\/\/fonts\.gstatic\.com/);
  assert.match(csp, /connect-src[^;]*https:\/\/\*\.supabase\.co/);
  assert.match(csp, /connect-src[^;]*wss:\/\/\*\.supabase\.co/);
  // Absent on purpose.
  assert.doesNotMatch(csp, /unpkg|esm\.sh|googletagmanager|google-analytics/);
});

test("clickjacking is refused two ways, for browsers that only know one", () => {
  const res = call("https://muster.partners/", "muster.partners");
  assert.match(res.headers.get("content-security-policy")!, /frame-ancestors 'none'/);
  assert.equal(res.headers.get("x-frame-options"), "DENY");
});

// Inline <style> and <script> are still in every page, so script-src has to
// permit them. Asserting it here means dropping 'unsafe-inline' later is a
// deliberate change to this test, not an accident that breaks six pages.
test("script-src still permits inline, and the test says why", () => {
  const csp = call("https://muster.partners/", "muster.partners").headers.get("content-security-policy")!;
  assert.match(csp, /script-src[^;]*'unsafe-inline'/,
    "every page ships one inline <script>; extract them before tightening this");
});

// HSTS comes from Vercel on this domain. Setting it here too would be a second
// source for one header, which is how the two drift apart.
test("HSTS is not set by the middleware", () => {
  const res = call("https://muster.partners/", "muster.partners");
  assert.equal(res.headers.get("strict-transport-security"), null);
});

test("muster.partners routes to the right page", () => {
  assert.equal(rewriteTarget(call("https://muster.partners/", "muster.partners")), "/index.html");
  assert.equal(rewriteTarget(call("https://muster.partners/privacy", "muster.partners")), "/privacy.html");
  assert.equal(rewriteTarget(call("https://muster.partners/onboarding", "muster.partners")), "/onboarding.html");
  assert.equal(rewriteTarget(call("https://muster.partners/sitrep", "muster.partners")), "/sitrep.html");
  assert.equal(rewriteTarget(call("https://muster.partners/sitrep/sample", "muster.partners")), "/sitrep-sample.html");
  assert.equal(rewriteTarget(call("https://muster.partners/beta", "muster.partners")), "/beta.html");
});

// The scanner reads these three by URL. If any of them is answered with a page
// instead of the file, GOV-001, GOV-002 or SEC-012 fires -- which is how the
// marketing site got its findings in the first place.
test("robots.txt, the sitemap and security.txt are served as files, not pages", () => {
  for (const path of ["/robots.txt", "/sitemap.xml", "/.well-known/security.txt"]) {
    const res = call(`https://muster.partners${path}`, "muster.partners");
    assert.equal(rewriteTarget(res), null, `${path} must fall through to the static file`);
  }
});

test("the app hosts get their own robots.txt, not the marketing site's", () => {
  const res = call("https://app.muster.partners/robots.txt", "app.muster.partners");
  assert.equal(rewriteTarget(res), "/robots-app.txt");
});

// A researcher who lands on an app host must find the policy, not a login form.
test("security.txt resolves on every host, including the app hosts", () => {
  for (const host of ["app.muster.partners", "sitrep.muster.28footsystems.com", "onboarding.muster.28footsystems.com"]) {
    const res = call(`https://${host}/.well-known/security.txt`, host);
    assert.equal(rewriteTarget(res), null, `${host} answered security.txt with a page`);
  }
});

// Regression guard for the reason signin.html and app.html share an origin.
test("the app hosts still serve both pages, and /reset lands on signin", () => {
  for (const host of ["app.muster.partners", "app.muster.28footsystems.com"]) {
    assert.equal(rewriteTarget(call(`https://${host}/app`, host)), "/app.html");
    assert.equal(rewriteTarget(call(`https://${host}/`, host)), "/signin.html");
    assert.equal(rewriteTarget(call(`https://${host}/signin`, host)), "/signin.html");
    assert.equal(rewriteTarget(call(`https://${host}/reset`, host)), "/signin.html");
  }
});

// The platform console shares the app origin deliberately: a Supabase session
// is stored per-origin, so a console served from anywhere else would load
// signed-out for someone who had just signed in. The route itself is not the
// gate -- muster_admin_console() raises 42501 for a non-super-admin -- so the
// only thing worth pinning here is that the path resolves on both app hosts.
test("the platform console is served from the app origin, not its own host", () => {
  for (const host of ["app.muster.partners", "app.muster.28footsystems.com"]) {
    assert.equal(rewriteTarget(call(`https://${host}/admin`, host)), "/admin.html");
    assert.equal(rewriteTarget(call(`https://${host}/admin/`, host)), "/admin.html");
  }
  // And nowhere else. /admin on the marketing site is not a console; it falls
  // through to a static file of that name, which does not exist.
  assert.equal(rewriteTarget(call("https://muster.partners/admin", "muster.partners")), null);
});

test("isUnder does not match a sibling with a shared prefix", () => {
  // /sitrepfoo is not part of the /sitrep family; on muster.partners it falls
  // through to a static file of that name, which does not exist.
  assert.equal(rewriteTarget(call("https://muster.partners/sitrepfoo", "muster.partners")), null);
  assert.equal(rewriteTarget(call("https://muster.partners/privacywall", "muster.partners")), null);
  assert.equal(rewriteTarget(call("https://muster.partners/betawall", "muster.partners")), null);
  // /administrator is not the console. On an app host it falls to signin.html
  // like any other unknown path, not to admin.html.
  assert.equal(rewriteTarget(call("https://app.muster.partners/administrator", "app.muster.partners")), "/signin.html");
});

test("a trailing slash resolves the same as no trailing slash", () => {
  assert.equal(rewriteTarget(call("https://muster.partners/privacy/", "muster.partners")), "/privacy.html");
  assert.equal(rewriteTarget(call("https://muster.partners/onboarding/", "muster.partners")), "/onboarding.html");
  assert.equal(rewriteTarget(call("https://muster.partners/beta/", "muster.partners")), "/beta.html");
});
