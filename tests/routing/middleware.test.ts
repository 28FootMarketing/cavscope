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
  ["https://muster.partners/", "muster.partners"],
  ["https://www.muster.partners/privacy", "www.muster.partners"],
  ["https://app.muster.partners/", "app.muster.partners"],
  ["https://app.muster.partners/app", "app.muster.partners"],
  ["https://app.muster.28footsystems.com/admin", "app.muster.28footsystems.com"],
  ["https://onboarding.muster.partners/", "onboarding.muster.partners"],
  ["https://sitrep.muster.28footsystems.com/sample", "sitrep.muster.28footsystems.com"],
  ["https://app.muster.partners/assets/favicon-32.png", "app.muster.partners"],
  ["https://cavscope.28footsystems.com/", "cavscope.28footsystems.com"],
  ["https://www.cavscope.28footsystems.com/", "www.cavscope.28footsystems.com"],
  ["https://cavscope.28footsystems.com/privacy", "cavscope.28footsystems.com"],
  ["https://cavscope.28footsystems.com/onboarding", "cavscope.28footsystems.com"],
  ["https://cavscope.28footsystems.com/sitrep", "cavscope.28footsystems.com"],
  ["https://cavscope.28footsystems.com/sitrep/sample", "cavscope.28footsystems.com"],
  ["https://cavscope.28footsystems.com/beta", "cavscope.28footsystems.com"],
  ["https://cavscope.28footsystems.com/app", "cavscope.28footsystems.com"],
  ["https://cavscope.28footsystems.com/admin", "cavscope.28footsystems.com"],
  ["https://cavscope.28footsystems.com/signin", "cavscope.28footsystems.com"],
  ["https://cavscope.28footsystems.com/reset", "cavscope.28footsystems.com"],
  ["https://cavscope.28footsystems.com/robots.txt", "cavscope.28footsystems.com"],
  ["https://cavscope.28footsystems.com/sitemap.xml", "cavscope.28footsystems.com"],
  ["https://cavscope.28footsystems.com/.well-known/security.txt", "cavscope.28footsystems.com"],
  ["https://cavscope.28footsystems.com/assets/favicon-32.png", "cavscope.28footsystems.com"],
];

test("every route carries every security header", () => {
  for (const [url, host] of EVERY_ROUTE) {
    const res = call(url, host);
    for (const h of SECURITY_HEADERS) {
      assert.ok(res.headers.get(h), `${h} missing on ${host}${new URL(url).pathname}`);
    }
  }
});

const CAV = "cavscope.28footsystems.com";

test("the CSP allows exactly the origins the pages actually load", () => {
  const csp = call(`https://${CAV}/`, CAV).headers.get("content-security-policy")!;
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
  const res = call(`https://${CAV}/`, CAV);
  assert.match(res.headers.get("content-security-policy")!, /frame-ancestors 'none'/);
  assert.equal(res.headers.get("x-frame-options"), "DENY");
});

// Inline <style> and <script> are still in every page, so script-src has to
// permit them. Asserting it here means dropping 'unsafe-inline' later is a
// deliberate change to this test, not an accident that breaks six pages.
test("script-src still permits inline, and the test says why", () => {
  const csp = call(`https://${CAV}/`, CAV).headers.get("content-security-policy")!;
  assert.match(csp, /script-src[^;]*'unsafe-inline'/,
    "every page ships one inline <script>; extract them before tightening this");
});

// HSTS comes from Vercel on this domain. Setting it here too would be a second
// source for one header, which is how the two drift apart.
test("HSTS is not set by the middleware", () => {
  const res = call(`https://${CAV}/`, CAV);
  assert.equal(res.headers.get("strict-transport-security"), null);
});

// The scanner reads these three by URL. If any of them is answered with a page
// instead of the file, GOV-001, GOV-002 or SEC-012 fires -- which is how the
// marketing site got its findings in the first place. robots.txt has its own
// merged file on this host, pinned below.
test("the sitemap and security.txt are served as files, not pages", () => {
  for (const path of ["/sitemap.xml", "/.well-known/security.txt"]) {
    assert.equal(rewriteTarget(call(`https://${CAV}${path}`, CAV)), null, `${path} must fall through to the static file`);
  }
});

test("the platform console is on the one CavScope origin", () => {
  assert.equal(rewriteTarget(call(`https://${CAV}/admin`, CAV)), "/admin.html");
  assert.equal(rewriteTarget(call(`https://${CAV}/admin/`, CAV)), "/admin.html");
});

test("isUnder does not match a sibling with a shared prefix", () => {
  // /sitrepfoo is not part of the /sitrep family; it falls through to a static
  // file of that name, which does not exist.
  assert.equal(rewriteTarget(call(`https://${CAV}/sitrepfoo`, CAV)), null);
  assert.equal(rewriteTarget(call(`https://${CAV}/privacywall`, CAV)), null);
  assert.equal(rewriteTarget(call(`https://${CAV}/betawall`, CAV)), null);
  // /administrator is not the console.
  assert.equal(rewriteTarget(call(`https://${CAV}/administrator`, CAV)), null);
});

test("a trailing slash resolves the same as no trailing slash", () => {
  assert.equal(rewriteTarget(call(`https://${CAV}/privacy/`, CAV)), "/privacy.html");
  assert.equal(rewriteTarget(call(`https://${CAV}/onboarding/`, CAV)), "/onboarding.html");
  assert.equal(rewriteTarget(call(`https://${CAV}/beta/`, CAV)), "/beta.html");
});

// cavscope.28footsystems.com is the one host for everything -- see
// middleware.js for why it does not need the old muster.partners /
// app.muster.partners split. These pin that every required path resolves and
// that root is marketing, not sign-in.
test("cavscope.28footsystems.com serves every required path from one host", () => {
  const host = "cavscope.28footsystems.com";
  assert.equal(rewriteTarget(call(`https://${host}/`, host)), "/index.html");
  assert.equal(rewriteTarget(call(`https://${host}/onboarding`, host)), "/onboarding.html");
  assert.equal(rewriteTarget(call(`https://${host}/app`, host)), "/app.html");
  assert.equal(rewriteTarget(call(`https://${host}/sitrep`, host)), "/sitrep.html");
  assert.equal(rewriteTarget(call(`https://${host}/sitrep/sample`, host)), "/sitrep-sample.html");
  assert.equal(rewriteTarget(call(`https://${host}/beta`, host)), "/beta.html");
  assert.equal(rewriteTarget(call(`https://${host}/admin`, host)), "/admin.html");
  assert.equal(rewriteTarget(call(`https://${host}/privacy`, host)), "/privacy.html");
  assert.equal(rewriteTarget(call(`https://${host}/signin`, host)), "/signin.html");
  assert.equal(rewriteTarget(call(`https://${host}/reset`, host)), "/signin.html");
});

test("www.cavscope.28footsystems.com is treated the same as the apex", () => {
  assert.equal(
    rewriteTarget(call("https://www.cavscope.28footsystems.com/", "www.cavscope.28footsystems.com")),
    "/index.html",
  );
});

test("cavscope.28footsystems.com gets its own merged robots.txt", () => {
  const res = call("https://cavscope.28footsystems.com/robots.txt", "cavscope.28footsystems.com");
  assert.equal(rewriteTarget(res), "/robots-cavscope.txt");
});

test("cavscope.28footsystems.com does not default unknown paths to sign-in", () => {
  // Unlike the legacy app hosts, root here is marketing, so an unmatched path
  // must fall through to a real static file (or 404), not silently become
  // the sign-in gate.
  const res = call("https://cavscope.28footsystems.com/nonexistent-page", "cavscope.28footsystems.com");
  assert.equal(rewriteTarget(res), null);
});

// ---- the retired MUSTER hosts ----------------------------------------------
//
// Since 2026-09-30 every MUSTER-era host answers with a permanent redirect to
// the same page on cavscope.28footsystems.com, so no page ever renders under
// the retired name and every link already delivered still works.

/** [status, location] for a request, or null when it was not a redirect. */
function redirect(url: string, host: string): [number, string] | null {
  const res = call(url, host);
  const loc = res.headers.get("location");
  return loc ? [res.status, loc] : null;
}

const TO = (path: string): [number, string] => [308, `https://${CAV}${path}`];

test("the old main site redirects each page to the same path on CavScope", () => {
  for (const host of ["muster.partners", "www.muster.partners", "muster.28footsystems.com"]) {
    for (const path of ["/", "/privacy", "/onboarding", "/sitrep", "/sitrep/sample", "/beta"]) {
      assert.deepEqual(redirect(`https://${host}${path}`, host), TO(path), `${host}${path}`);
    }
  }
});

test("the old app hosts send sign-in, workspace, console and reset to their CavScope paths", () => {
  for (const host of ["app.muster.partners", "app.muster.28footsystems.com"]) {
    // Root on the app hosts was the sign-in page; root on CavScope is marketing.
    assert.deepEqual(redirect(`https://${host}/`, host), TO("/signin"));
    assert.deepEqual(redirect(`https://${host}/signin`, host), TO("/signin"));
    assert.deepEqual(redirect(`https://${host}/app`, host), TO("/app"));
    assert.deepEqual(redirect(`https://${host}/admin`, host), TO("/admin"));
    assert.deepEqual(redirect(`https://${host}/reset`, host), TO("/reset"));
    // Any other path there meant the sign-in page, and still does.
    assert.deepEqual(redirect(`https://${host}/administrator`, host), TO("/signin"));
  }
});

test("the old onboarding and sitrep hosts land on their CavScope pages", () => {
  for (const host of ["onboarding.muster.partners", "onboarding.muster.28footsystems.com"]) {
    assert.deepEqual(redirect(`https://${host}/`, host), TO("/onboarding"));
  }
  for (const host of ["sitrep.muster.partners", "sitrep.muster.28footsystems.com"]) {
    assert.deepEqual(redirect(`https://${host}/`, host), TO("/sitrep"));
    assert.deepEqual(redirect(`https://${host}/sample`, host), TO("/sitrep/sample"));
  }
});

// Invites and onboarding links can carry a query string. The #fragment of an
// auth link never reaches the server, and a browser carries it across a
// redirect whose Location has none -- which is why none is ever added here.
test("a redirect keeps the query string and never sets a fragment", () => {
  assert.deepEqual(
    redirect("https://onboarding.muster.28footsystems.com/?invite=abc", "onboarding.muster.28footsystems.com"),
    TO("/onboarding?invite=abc"),
  );
  const [, loc] = redirect("https://app.muster.partners/app", "app.muster.partners")!;
  assert.ok(!loc.includes("#"));
});

// A researcher who reaches an old host must still find the policy.
test("security.txt on an old host redirects to the CavScope copy, not to a page", () => {
  for (const host of ["app.muster.partners", "muster.partners", "sitrep.muster.28footsystems.com", "onboarding.muster.28footsystems.com"]) {
    assert.deepEqual(redirect(`https://${host}/.well-known/security.txt`, host), TO("/.well-known/security.txt"), host);
  }
});

test("no MUSTER-era host is ever served a page", () => {
  for (const [url, host] of EVERY_ROUTE) {
    if (!host.includes("muster")) continue;
    const res = call(url, host);
    assert.equal(rewriteTarget(res), null, `${url} rendered a page`);
    assert.equal(res.status, 308, `${url} was not redirected`);
  }
});
