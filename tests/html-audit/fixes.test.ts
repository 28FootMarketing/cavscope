// The HTML audit's pure half: the engine's own page rules on pasted HTML, and
// the fixes an operator chooses.
//
//   node --experimental-strip-types --test tests/html-audit/fixes.test.ts
//
// The audit is for a one-off site CavScope does not scan: paste the HTML, see
// what the engine would say, fix what can be fixed, take the HTML back. Two
// things it must never do: invent words on the site owner's behalf (alt text,
// titles, labels come from a person or not at all), and claim the page is clean
// on checks HTML cannot show (headers, cookies, DNS), which NOT_CHECKED states
// on every result.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import {
  audit, applyFixes, contextFor, sriCandidates, isFetchableScriptUrl, sriFor, looksVersioned,
  FIXES, NOT_CHECKED, LANGUAGES, SRI_RE,
} from "../../supabase/functions/cavscope-html-audit/fixes.ts";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const engine = readFileSync(join(root, "supabase/functions/muster-scan/index.ts"), "utf8");
const pageChecks = readFileSync(join(root, "supabase/functions/muster-scan/page-checks.ts"), "utf8");

const URL_ = "https://shop.example.com/";
const BAD = `<!doctype html><html><head><title></title><meta name="viewport" content="width=device-width, user-scalable=no, maximum-scale=1">
<script src="https://cdn.jsdelivr.net/npm/lib@1.2.3/x.js"></script><script src="https://www.googletagmanager.com/gtm.js?id=G"></script>
<link rel="stylesheet" href="http://old.example.org/a.css"></head><body>
<a href="/x"><img src="logo.png"></a><img src="http://img.example.org/b.png">
<form action="http://forms.example.org/post"><input name="email" placeholder="Email"></form>
<a href="https://facebook.com/x"></a><p>Hello there</p></body></html>`;

const ids = (html: string, url = URL_) => audit(html, url).findings.map((f) => f.rule_id);

test("the audit runs the scan engine's own page rules, not a copy", () => {
  assert.match(engine, /from "\.\/page-checks\.ts"/, "the engine must import the shared module");
  assert.doesNotMatch(engine, /rule_id: "A11Y-003"/, "the engine must not carry its own copy of a page rule");
  assert.match(pageChecks, /rule_id: "A11Y-003"/);
  const src = readFileSync(join(root, "supabase/functions/cavscope-html-audit/fixes.ts"), "utf8");
  assert.match(src, /from "\.\.\/muster-scan\/page-checks\.ts"/);
});

test("a page with every defect raises every page rule", () => {
  const found = ids(BAD);
  for (const id of ["A11Y-001", "A11Y-002", "A11Y-003", "A11Y-004", "A11Y-005", "A11Y-006", "A11Y-007",
    "PRIV-001", "PRIV-002", "PRIV-003", "PRIV-004", "SEC-010", "SEC-014", "TP-001", "GOV-003", "GOV-005", "GOV-007"]) {
    assert.ok(found.includes(id), `${id} should fire`);
  }
});

test("every rule the audit can raise has a fix description and instructions", () => {
  const found = new Set(ids(BAD));
  for (const id of found) {
    const f = FIXES[id];
    assert.ok(f, `${id} has no FIXES entry`);
    assert.ok(["auto", "input", "manual"].includes(f.mode));
    assert.ok(f.does.length > 20 && f.howTo.length > 20, `${id} needs real words`);
  }
  // Rules that can only be judged against the live server are never raised here.
  for (const id of found) assert.doesNotMatch(id, /^(SEC-00[1-9]|COOK|EMAIL|AVAIL|DNS)/);
});

test("the scope note names what pasted HTML cannot show", () => {
  const all = NOT_CHECKED.join(" ");
  for (const w of ["headers", "Cookies", "HTTPS", "SPF", "robots.txt"]) assert.ok(all.includes(w), w);
});

test("without a page address the audit says it assumed one", () => {
  assert.equal(contextFor(null).assumed, true);
  assert.equal(contextFor("javascript:alert(1)").assumed, true);
  assert.equal(contextFor("not a url").assumed, true);
  const c = contextFor("http://Shop.Example.com/a");
  assert.deepEqual([c.host, c.isHttps, c.assumed], ["shop.example.com", false, false]);
  // Mixed content only exists on an https page.
  assert.ok(!ids(BAD, "http://shop.example.com/").includes("SEC-010"));
});

test("nothing chosen, nothing changed", () => {
  const r = applyFixes(BAD, URL_, {});
  assert.equal(r.html, BAD);
  assert.deepEqual(r.changes, []);
});

test("every fix applied clears its finding, and only its finding", () => {
  const r = applyFixes(BAD, URL_, {
    lang: "en", title: "Acme shop", alts: ["Acme logo", "Product photo"], fixZoom: true,
    fieldLabels: ["Email address"], linkLabels: ["Home", "Acme on Facebook"],
    privacyUrl: "https://shop.example.com/privacy", termsUrl: "https://shop.example.com/terms",
    upgradeForms: true, upgradeMixed: true, description: "Acme sells things.", canonical: URL_,
    org: { name: "Acme", url: URL_ }, sri: { "https://cdn.jsdelivr.net/npm/lib@1.2.3/x.js": "sha384-AAAA" },
  });
  const after = ids(r.html);
  for (const id of ["A11Y-001", "A11Y-002", "A11Y-003", "A11Y-004", "A11Y-006", "A11Y-007", "PRIV-001",
    "PRIV-004", "SEC-010", "SEC-014", "GOV-003", "GOV-005", "GOV-007"]) {
    assert.ok(!after.includes(id), `${id} should be fixed`);
  }
  // Manual ones stay: a heading's place, trackers without consent, an outside form host.
  for (const id of ["A11Y-005", "PRIV-002", "TP-001", "PRIV-003"]) assert.ok(after.includes(id), `${id} is not auto-fixable`);
  assert.match(r.html, /action="https:\/\/forms\.example\.org\/post"/, "the form still moved to https");
  assert.equal(r.changes.length, 14);
});

test("positional answers land on the right tags, even when a link wraps an image", () => {
  const r = applyFixes(BAD, URL_, { alts: ["Acme logo", "Product photo"], linkLabels: ["Home", "Facebook"], upgradeMixed: true });
  assert.match(r.html, /<a href="\/x" aria-label="Home"><img src="logo\.png" alt="Acme logo"><\/a>/);
  assert.match(r.html, /<img src="https:\/\/img\.example\.org\/b\.png" alt="Product photo">/, "alt and https both land on the same image");
  assert.match(r.html, /<a href="https:\/\/facebook\.com\/x" aria-label="Facebook"><\/a>/);
});

test("a blank answer skips that tag; an explicit empty alt marks it decorative", () => {
  const r = applyFixes(BAD, URL_, { alts: [null, ""], linkLabels: ["", "Facebook"], fieldLabels: ["   "] });
  assert.match(r.html, /<img src="logo\.png">/, "null leaves the first image alone");
  assert.match(r.html, /<img src="http:\/\/img\.example\.org\/b\.png" alt="">/, "empty string is decorative");
  assert.match(r.changes.find((c) => c.rule_id === "A11Y-003")!.summary, /1 of them marked decorative/);
  assert.match(r.html, /<a href="\/x"><img/, "a blank link label is skipped");
  assert.ok(!r.changes.some((c) => c.rule_id === "A11Y-006"), "whitespace is not a label");
});

test("identical tags are matched in document order", () => {
  const html = `<html lang="en"><head><title>t</title></head><body><h1>x</h1><img src="a.png"><img src="a.png"></body></html>`;
  const r = applyFixes(html, URL_, { alts: ["first", "second"] });
  assert.ok(r.html.indexOf('alt="first"') < r.html.indexOf('alt="second"'));
});

test("text is escaped, never interpreted", () => {
  const r = applyFixes(BAD, URL_, {
    title: `Tom & "Jerry" $& <b>`, description: `a "quote" <script>`, alts: [`x" onerror="alert(1)`, null],
    org: { name: "Evil </script><script>alert(1)</script>" },
  });
  assert.match(r.html, /<title>Tom &amp; "Jerry" \$&amp; &lt;b&gt;<\/title>/);
  assert.match(r.html, /content="a &quot;quote&quot; &lt;script&gt;"/);
  assert.match(r.html, /alt="x&quot; onerror=&quot;alert\(1\)"/);
  const ld = r.html.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/)![1];
  assert.doesNotMatch(ld, /<\/script/i, "JSON-LD cannot close its own element");
  assert.equal(JSON.parse(ld).name, "Evil </script><script>alert(1)</script>");
});

test("invalid choices are skipped, not coerced", () => {
  const r = applyFixes(BAD, URL_, {
    lang: "english please", privacyUrl: "javascript:alert(1)", termsUrl: "/terms", canonical: "data:text/html,x",
    sri: { "https://cdn.jsdelivr.net/npm/lib@1.2.3/x.js": "md5-abc" }, org: { name: "  " },
  });
  assert.deepEqual(r.changes, []);
  assert.equal(r.html, BAD);
});

test("a fix is applied only where its finding exists", () => {
  const clean = `<html lang="fr"><head><title>Bonjour</title></head><body><h1>x</h1></body></html>`;
  const r = applyFixes(clean, URL_, { lang: "en", title: "Hello" });
  assert.match(r.html, /lang="fr"/);
  assert.match(r.html, /<title>Bonjour<\/title>/);
  assert.deepEqual(r.changes, []);
});

test("zoom keeps every other viewport setting", () => {
  const html = `<html><head><meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1.0, user-scalable=0"></head></html>`;
  const r = applyFixes(html, URL_, { fixZoom: true });
  assert.match(r.html, /content="width=device-width, initial-scale=1"/);
  const ok = `<html><head><meta name="viewport" content="width=device-width, maximum-scale=5"></head></html>`;
  assert.equal(applyFixes(ok, URL_, { fixZoom: true }).html, ok, "maximum-scale 5 is allowed zoom");
});

test("head and footer insertions find their place, or make one", () => {
  const noHead = `<html><body><p>x</p></body></html>`;
  assert.match(applyFixes(noHead, URL_, { description: "d" }).html, /<html>\n<head><meta name="description" content="d"><\/head>/);
  const footer = `<html><head></head><body><footer><p>(c)</p></footer></body></html>`;
  assert.match(applyFixes(footer, URL_, { privacyUrl: "https://x.co/p" }).html, /<a href="https:\/\/x\.co\/p">Privacy Policy<\/a>\n<\/footer>/);
});

test("an https upgrade touches only http:// references", () => {
  const html = `<html><head><link rel="stylesheet" href="http://a.co/x.css"><link rel="canonical" href="http://shop.example.com/"></head><body><img src="https://b.co/y.png"></body></html>`;
  const r = applyFixes(html, URL_, { upgradeMixed: true });
  assert.match(r.html, /href="https:\/\/a\.co\/x\.css"/);
  assert.match(r.html, /rel="canonical" href="http:\/\/shop\.example\.com\/"/, "a canonical link is not a loaded resource");
});

test("SRI candidates skip tag managers, own-host and already-pinned scripts", () => {
  const html = `<script src="https://cdn.jsdelivr.net/npm/a@1.0.0/a.js"></script>
<script src="https://code.jquery.com/jquery.js"></script>
<script src="https://www.googletagmanager.com/gtag/js?id=G"></script>
<script src="/local.js"></script><script src="https://shop.example.com/own.js"></script>
<script src="https://cdnjs.cloudflare.com/x/1.2.3/x.js" integrity="sha384-x" crossorigin="anonymous"></script>
<script src="//unpkg.com/b@2.0.1/b.js"></script>`;
  const c = sriCandidates(html, URL_);
  assert.deepEqual(c.map((s) => s.src), ["https://cdn.jsdelivr.net/npm/a@1.0.0/a.js", "https://code.jquery.com/jquery.js", "//unpkg.com/b@2.0.1/b.js"]);
  assert.deepEqual(c.map((s) => s.versioned), [true, false, true]);
  assert.equal(c[2].url, "https://unpkg.com/b@2.0.1/b.js", "protocol-relative resolves against the page");
});

test("versioned means pinned to a release, not merely containing a number", () => {
  assert.ok(looksVersioned("https://cdn.jsdelivr.net/npm/lib@3.7.1/dist/x.js"));
  assert.ok(looksVersioned("https://example.org/wp-includes/js/jquery.min.js?ver=3.7.1"));
  assert.ok(looksVersioned("https://cdnjs.cloudflare.com/ajax/libs/lodash.js/4.17.21/lodash.min.js"));
  assert.ok(!looksVersioned("https://code.jquery.com/jquery-latest.js"));
  assert.ok(!looksVersioned("https://widget.example.com/embed.js"));
});

test("the server fetches a script to hash it only from a public https name", () => {
  for (const ok of ["https://cdn.jsdelivr.net/npm/a@1/a.js", "https://code.jquery.com/jquery-3.7.1.min.js"]) {
    assert.ok(isFetchableScriptUrl(ok), ok);
  }
  for (const bad of [
    "http://cdn.jsdelivr.net/a.js", "https://127.0.0.1/a.js", "https://169.254.169.254/latest", "https://[::1]/a.js",
    "https://localhost/a.js", "https://metadata.google.internal/a.js", "https://intranet/a.js", "https://0x7f000001/a.js",
    "https://user:pw@cdn.example.net/a.js", "https://cdn.example.net:8443/a.js", "file:///etc/passwd", "https://x.local/a.js",
  ]) {
    assert.ok(!isFetchableScriptUrl(bad), bad);
  }
});

test("the integrity value is sha384 of the bytes, in the browser's format", async () => {
  const v = await sriFor(new TextEncoder().encode("alert(1)"));
  assert.match(v, SRI_RE);
  // openssl dgst -sha384 -binary <<< -n 'alert(1)' | base64
  const { createHash } = await import("node:crypto");
  assert.equal(v, "sha384-" + createHash("sha384").update("alert(1)").digest("base64"));
});

test("the language dropdown offers valid codes only", () => {
  for (const [code, label] of LANGUAGES) {
    assert.match(code, /^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$/);
    assert.ok(label.length > 1);
  }
});
