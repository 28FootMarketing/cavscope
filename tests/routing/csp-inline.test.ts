// The Content-Security-Policy names every inline script by hash, and the hashes
// match the pages that ship.
//
//   node --experimental-strip-types --test tests/routing/csp-inline.test.ts
//
// Until 2026-10-11 script-src said 'unsafe-inline', and CavScope's own SEC-018
// reported it against this site (scan 332, finding 3378): a policy that still
// allows the one thing injection needs. Now tools/csp/sync.mjs writes one
// 'sha256-...' per inline <script> block and, under 'unsafe-hashes', one per
// distinct inline event handler into tools/csp/manifest.js, and middleware.js
// puts the right page's set on its response. That is only safe while the
// manifest matches the pages byte for byte -- a stale hash means the browser
// refuses the page's script in production and nothing in a source-reading test
// would notice -- so this file is the second half of the arrangement, the way
// tests/ui/design-tokens.test.ts is for the tokens.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import middleware, { cspFor } from "../../middleware.js";
import MANIFEST from "../../tools/csp/manifest.js";
import { PAGES, hashesFor, inlineScripts, inlineHandlers, sha256 } from "../../tools/csp/sync.mjs";
import { PAGES as TOKEN_PAGES } from "../../tools/tokens/sync.mjs";
import { evaluateCspQuality } from "../../supabase/functions/cavscope-scan/csp.ts";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const CAV = "cavscope.28footsystems.com";
const page = (file: string) => readFileSync(join(ROOT, file), "utf8");

const call = (path: string): Response =>
  middleware(new Request(`https://${CAV}${path}`, { headers: { host: CAV } })) as Response;

const scriptSrc = (csp: string): string[] => {
  const part = csp.split(";").map((p) => p.trim()).find((p) => p.startsWith("script-src "));
  assert.ok(part, "no script-src directive");
  return part!.split(/\s+/).slice(1);
};

// Which routed path serves which file. /beta redirects and beta.html is kept
// unrouted, so it is reachable only by its file name.
const ROUTES: Array<[string, string]> = [
  ["/", "index.html"],
  ["/app", "app.html"],
  ["/signin", "signin.html"],
  ["/reset", "signin.html"],
  ["/onboarding", "onboarding.html"],
  ["/sitrep", "sitrep.html"],
  ["/sitrep/sample", "sitrep-sample.html"],
  ["/admin", "admin.html"],
  ["/privacy", "privacy.html"],
  ["/terms", "terms.html"],
  ["/audit/html", "html-audit.html"],
  ["/beta.html", "beta.html"],
];

test("the page list is the same one the token sync uses", () => {
  assert.deepEqual([...PAGES].sort(), [...TOKEN_PAGES].sort());
  assert.deepEqual(Object.keys(MANIFEST).sort(), [...PAGES].sort());
});

test("the manifest matches every page as shipped -- run node tools/csp/sync.mjs if not", () => {
  for (const file of PAGES) {
    assert.deepEqual(MANIFEST[file], hashesFor(page(file), file),
      `${file} has changed since tools/csp/manifest.js was written -- run: node tools/csp/sync.mjs`);
  }
});

test("every page has at least one inline block to name, and the hashes are quoted CSP sources", () => {
  for (const file of PAGES) {
    const m = MANIFEST[file];
    assert.ok(m.scripts.length >= 1, `${file}: no inline <script> found, which this repo's pages all have`);
    for (const h of [...m.scripts, ...m.handlers]) assert.match(h, /^'sha256-[A-Za-z0-9+/]{43}='$/, `${file}: ${h}`);
  }
});

test("no routed page's script-src says unsafe-inline, unsafe-eval or *", () => {
  for (const [path] of ROUTES) {
    const src = scriptSrc(call(path).headers.get("content-security-policy")!);
    assert.ok(!src.includes("'unsafe-inline'"), `${path}: 'unsafe-inline' is back on script-src`);
    assert.ok(!src.includes("'unsafe-eval'"), `${path}: 'unsafe-eval' on script-src`);
    assert.ok(!src.includes("*"), `${path}: bare wildcard on script-src`);
  }
});

test("the engine's own SEC-018 rule passes every routed page's policy", () => {
  for (const [path] of ROUTES) {
    const csp = call(path).headers.get("content-security-policy")!;
    assert.deepEqual(evaluateCspQuality({ csp, evidenceKey: "headers" }), [], `${path} would still report SEC-018`);
  }
});

test("each routed page's script-src carries exactly its own file's hashes", () => {
  for (const [path, file] of ROUTES) {
    const src = scriptSrc(call(path).headers.get("content-security-policy")!);
    const m = MANIFEST[file];
    for (const h of m.scripts) assert.ok(src.includes(h), `${path}: missing block hash from ${file}`);
    for (const h of m.handlers) assert.ok(src.includes(h), `${path}: missing handler hash from ${file}`);
    assert.equal(src.includes("'unsafe-hashes'"), m.handlers.length > 0,
      `${path}: 'unsafe-hashes' is present only when the page has inline handlers`);
    // And nothing from another page: the hashes on the header are the file's and the hosts, no more.
    const expected = new Set(["'self'", "https://cdn.jsdelivr.net", ...m.scripts, ...m.handlers, ...(m.handlers.length ? ["'unsafe-hashes'"] : [])]);
    for (const token of src) assert.ok(expected.has(token), `${path}: unexpected script-src token ${token}`);
  }
});

test("a page asked for by its file name gets the same policy as its route", () => {
  for (const [path, file] of ROUTES) {
    if (path === `/${file}`) continue;
    assert.equal(call(`/${file}`).headers.get("content-security-policy"), call(path).headers.get("content-security-policy"),
      `/${file} and ${path} serve the same file and must carry the same policy`);
  }
});

test("a response that serves no page names no inline script at all", () => {
  for (const path of ["/assets/favicon-32.png", "/sitemap.xml", "/.well-known/security.txt", "/llms.txt", "/robots.txt", "/no-such-page"]) {
    const src = scriptSrc(call(path).headers.get("content-security-policy")!);
    assert.deepEqual(src, ["'self'", "https://cdn.jsdelivr.net"], path);
  }
  assert.deepEqual(scriptSrc(cspFor(null)), ["'self'", "https://cdn.jsdelivr.net"]);
});

test("the other directives did not move when script-src did", () => {
  const csp = call("/").headers.get("content-security-policy")!;
  for (const d of ["default-src 'self'", "base-uri 'self'", "object-src 'none'", "frame-ancestors 'none'", "form-action 'self'",
    "img-src 'self' data:", "font-src 'self' https://fonts.gstatic.com", "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
    "connect-src 'self' https://*.supabase.co wss://*.supabase.co", "upgrade-insecure-requests"]) {
    assert.ok(csp.split("; ").includes(d), `missing directive: ${d}`);
  }
});

// A handler whose text differs per row has no one hash. The browser would refuse
// it and the button would silently do nothing, so the tool refuses first.
test("the tool refuses an inline handler built from data, and no page has one", () => {
  assert.throws(() => inlineHandlers('<button onclick="Live.revokeKey(${k.id})">x</button>', "t"), /built from data/);
  assert.throws(() => inlineHandlers("<button onclick=\"go('a\\'b')\">x</button>", "t"), /backslash/);
  assert.throws(() => inlineHandlers('<button onclick="go(&nbsp;)">x</button>', "t"), /entity/);
  for (const file of PAGES) assert.doesNotThrow(() => inlineHandlers(page(file), file));
});

// The browser hashes the attribute's decoded value, not its source text.
test("handler hashes are over the decoded attribute value", () => {
  const [h] = inlineHandlers('<a onclick="say(&quot;hi&quot;) &amp;&amp; go()">x</a>');
  assert.equal(h, 'say("hi") && go()');
  assert.equal(sha256(h), "'sha256-" + createHash("sha256").update('say("hi") && go()').digest("base64") + "'");
});

test("only executable inline blocks are hashed: JSON-LD and src= scripts are not", () => {
  const html = `<script type="application/ld+json">{"a":1}</script><script src="x.js"></script><script>run();</script><script type="module">m();</script>`;
  assert.deepEqual(inlineScripts(html), ["run();", "m();"]);
  // index.html carries a JSON-LD block; it must not be in the manifest.
  assert.equal(inlineScripts(page("index.html")).some((s) => s.includes('"@context"')), false);
});

// The rows app.html renders from data went through onclick="fn(\${id})" until
// 2026-10-11; they are dispatched by data-act now. A new one written the old way
// fails the manifest test above; this names the mechanism it should use instead.
test("app.html dispatches its data-built rows through data-act and one delegated listener", () => {
  const html = page("app.html");
  assert.match(html, /function initActionDelegation\(\)/);
  assert.match(html, /initTooltips\(\); initAccordions\(\); initContextMenuGuard\(\); initModalA11y\(\); initActionDelegation\(\);/);
  const acts = [...html.matchAll(/data-act="([a-z-]+)"/g)].map((m) => m[1]);
  assert.ok(acts.length >= 8, `expected the data-built rows to carry data-act, found ${acts.length}`);
  for (const act of new Set(acts)) assert.match(html, new RegExp(`'${act}': \\{ event: '(click|change)'`), `no ACTIONS entry for ${act}`);
});
