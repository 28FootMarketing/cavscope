// SEC-014 / SEC-015 / EMAIL-008 rule logic, tested against the shipped module.
//
//   node --experimental-strip-types --test tests/scan/hardening.test.ts
//
// All three accuse a customer of a supply-chain or transport weakness on the
// strength of a regex or a DNS answer. As with the EMAIL family, the expensive
// failure is not missing a real problem -- it is issuing advice that is wrong or
// that cannot be acted on. Most of what follows guards that direction, and the
// tag-manager exclusion in SEC-014 is the single most important case in the file:
// "add SRI to Google Tag Manager" is advice that breaks the site.

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  caaNames,
  evaluateCaa,
  evaluateMtaSts,
  evaluateSubresourceIntegrity,
  extractScripts,
  isMutableByDesign,
} from "../../supabase/functions/muster-scan/hardening.ts";

const PAGE = "https://example.com/";
const HOST = "example.com";

// --- extractScripts ---------------------------------------------------------

test("extractScripts ignores same-origin scripts and inline scripts", () => {
  const html = `
    <script>var a = 1;</script>
    <script src="/local.js"></script>
    <script src="https://example.com/also-local.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/thing.js"></script>`;
  const out = extractScripts(html, PAGE, HOST);
  assert.equal(out.length, 1);
  assert.equal(out[0].host, "cdn.jsdelivr.net");
});

test("extractScripts reads integrity and crossorigin off the tag, in any quoting", () => {
  const html = `
    <script src="https://a.example.net/1.js" integrity="sha384-abc" crossorigin="anonymous"></script>
    <script src='https://b.example.net/2.js' integrity='sha256-def'></script>
    <script src=https://c.example.net/3.js></script>`;
  const out = extractScripts(html, PAGE, HOST);
  assert.deepEqual(out.map((s) => [s.host, s.hasIntegrity, s.hasCrossOrigin]), [
    ["a.example.net", true, true],
    ["b.example.net", true, false],
    ["c.example.net", false, false],
  ]);
});

test("extractScripts resolves protocol-relative and relative-host srcs", () => {
  const out = extractScripts(`<script src="//cdn.example.net/x.js"></script>`, PAGE, HOST);
  assert.equal(out.length, 1);
  assert.equal(out[0].host, "cdn.example.net");
});

test("extractScripts survives a malformed src without throwing", () => {
  const out = extractScripts(`<script src="ht!tp://[bad"></script><script src=""></script>`, PAGE, HOST);
  assert.deepEqual(out, []);
});

// --- SEC-014 ----------------------------------------------------------------

test("SEC-014 does NOT fire on tag managers and analytics, which change by design", () => {
  // The case that matters most. Every one of these is a vendor whose file is
  // meant to change; pinning a hash breaks the tag on the vendor's next deploy.
  const html = `
    <script src="https://www.googletagmanager.com/gtm.js?id=GTM-X"></script>
    <script src="https://connect.facebook.net/en_US/fbevents.js"></script>
    <script src="https://static.hotjar.com/c/hotjar-1.js"></script>
    <script src="https://js.stripe.com/v3/"></script>`;
  const findings = evaluateSubresourceIntegrity({
    scripts: extractScripts(html, PAGE, HOST),
    evidenceKey: "scripts",
  });
  assert.deepEqual(findings, []);
});

test("SEC-014 fires on a pinnable CDN script with no integrity", () => {
  const html = `<script src="https://cdn.jsdelivr.net/npm/chart.js@4/dist/chart.js"></script>`;
  const findings = evaluateSubresourceIntegrity({
    scripts: extractScripts(html, PAGE, HOST),
    evidenceKey: "scripts",
  });
  assert.equal(findings.length, 1);
  assert.equal(findings[0].rule_id, "SEC-014");
  assert.equal(findings[0].severity, "medium");
  assert.match(findings[0].detail, /cdn\.jsdelivr\.net/);
});

test("SEC-014 stays silent when every pinnable script is pinned", () => {
  const html = `
    <script src="https://cdn.jsdelivr.net/npm/a.js" integrity="sha384-x" crossorigin="anonymous"></script>
    <script src="https://www.googletagmanager.com/gtm.js"></script>`;
  assert.deepEqual(
    evaluateSubresourceIntegrity({ scripts: extractScripts(html, PAGE, HOST), evidenceKey: "scripts" }),
    [],
  );
});

test("SEC-014 names integrity-without-crossorigin, which looks pinned and is not", () => {
  const html = `
    <script src="https://cdn.jsdelivr.net/npm/a.js" integrity="sha384-x"></script>
    <script src="https://unpkg.com/b.js"></script>`;
  const [f] = evaluateSubresourceIntegrity({ scripts: extractScripts(html, PAGE, HOST), evidenceKey: "scripts" });
  assert.match(f.detail, /no crossorigin/i);
});

test("SEC-014 says how many scripts it excluded rather than hiding them", () => {
  const html = `
    <script src="https://unpkg.com/b.js"></script>
    <script src="https://www.googletagmanager.com/gtm.js"></script>
    <script src="https://cdn.segment.com/analytics.js"></script>`;
  const [f] = evaluateSubresourceIntegrity({ scripts: extractScripts(html, PAGE, HOST), evidenceKey: "scripts" });
  assert.match(f.detail, /2 further script/);
  assert.match(f.detail, /CSP/);
});

test("isMutableByDesign is host-matched, not substring-matched into arbitrary names", () => {
  assert.equal(isMutableByDesign("www.googletagmanager.com"), true);
  assert.equal(isMutableByDesign("cdn.jsdelivr.net"), false);
  assert.equal(isMutableByDesign("unpkg.com"), false);
  assert.equal(isMutableByDesign("cdnjs.cloudflare.com"), false);
});

// --- SEC-015 ----------------------------------------------------------------

test("caaNames walks from the host up to the registrable domain and stops", () => {
  assert.deepEqual(caaNames("www.example.com", "example.com"), ["www.example.com", "example.com"]);
  assert.deepEqual(caaNames("a.b.example.co.uk", "example.co.uk"), ["a.b.example.co.uk", "b.example.co.uk", "example.co.uk"]);
  assert.deepEqual(caaNames("example.com", "example.com"), ["example.com"]);
});

test("caaNames never walks past the registrable domain into the public suffix", () => {
  for (const n of caaNames("www.example.co.uk", "example.co.uk")) {
    assert.notEqual(n, "co.uk");
    assert.notEqual(n, "uk");
  }
});

test("SEC-015 fires only when every queried name came back empty", () => {
  const empty = evaluateCaa({
    host: "example.com",
    answers: [{ name: "www.example.com", records: [] }, { name: "example.com", records: [] }],
    evidenceKey: "dns_caa",
  });
  assert.equal(empty.length, 1);
  assert.equal(empty[0].rule_id, "SEC-015");

  const present = evaluateCaa({
    host: "example.com",
    answers: [{ name: "www.example.com", records: [] }, { name: "example.com", records: ['0 issue "letsencrypt.org"'] }],
    evidenceKey: "dns_caa",
  });
  assert.deepEqual(present, []);
});

test("SEC-015 is silent when the resolver failed, so an outage is never a finding", () => {
  assert.deepEqual(
    evaluateCaa({ host: "example.com", answers: [], resolverFailed: true, evidenceKey: "dns_caa" }),
    [],
  );
});

// --- EMAIL-008 --------------------------------------------------------------

const MX = ["10 mail.example.com."];

test("EMAIL-008 is silent on a domain that accepts no mail", () => {
  assert.deepEqual(
    evaluateMtaSts({ domain: "example.com", txt: [], policy: null, mx: [], evidenceKey: "mta_sts" }),
    [],
  );
});

test("EMAIL-008 is silent when the resolver failed", () => {
  assert.deepEqual(
    evaluateMtaSts({ domain: "example.com", txt: [], policy: null, mx: MX, resolverFailed: true, evidenceKey: "mta_sts" }),
    [],
  );
});

test("EMAIL-008 fires when a mail-accepting domain publishes no record", () => {
  const [f] = evaluateMtaSts({ domain: "example.com", txt: [], policy: null, mx: MX, evidenceKey: "mta_sts" });
  assert.equal(f.rule_id, "EMAIL-008");
  assert.match(f.detail, /publishes no MTA-STS policy/);
});

test("EMAIL-008 catches a record with no policy served, which looks configured", () => {
  const [f] = evaluateMtaSts({
    domain: "example.com", txt: ["v=STSv1; id=20260101T000000;"], policy: null, mx: MX, evidenceKey: "mta_sts",
  });
  assert.match(f.detail, /did not return a policy/);
});

test("EMAIL-008 treats testing mode as not enforcing, and enforce as clean", () => {
  const testing = evaluateMtaSts({
    domain: "example.com", txt: ["v=STSv1; id=1;"],
    policy: "version: STSv1\nmode: testing\nmx: mail.example.com\nmax_age: 604800\n", mx: MX, evidenceKey: "mta_sts",
  });
  assert.equal(testing.length, 1);
  assert.match(testing[0].detail, /"testing"/);

  const enforce = evaluateMtaSts({
    domain: "example.com", txt: ["v=STSv1; id=1;"],
    policy: "version: STSv1\nmode: enforce\nmx: mail.example.com\nmax_age: 604800\n", mx: MX, evidenceKey: "mta_sts",
  });
  assert.deepEqual(enforce, []);
});

test("every finding carries the evidence key it was told to cite", () => {
  const all = [
    ...evaluateSubresourceIntegrity({ scripts: extractScripts('<script src="https://unpkg.com/a.js"></script>', PAGE, HOST), evidenceKey: "scripts" }),
    ...evaluateCaa({ host: "example.com", answers: [{ name: "example.com", records: [] }], evidenceKey: "dns_caa" }),
    ...evaluateMtaSts({ domain: "example.com", txt: [], policy: null, mx: MX, evidenceKey: "mta_sts" }),
  ];
  assert.equal(all.length, 3, "all three rules should have fired in this fixture");
  assert.deepEqual(all.map((f) => f.evidence_keys), [["scripts"], ["dns_caa"], ["mta_sts"]]);
});
