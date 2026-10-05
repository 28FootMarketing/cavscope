// Page discovery and host logic for the browser engine. Pure.
//   node --experimental-strip-types --test tests/browser/discover.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
// @ts-ignore
import * as d from "../../workers/browser-scan/lib/discover.mjs";
// @ts-ignore
import * as h from "../../workers/browser-scan/lib/hosts.mjs";

test("sitemap: urlset locs, index kind, entities decoded", () => {
  const a = d.parseSitemap("<urlset><url><loc>https://x.com/a?b=1&amp;c=2</loc></url><url><loc> https://x.com/b </loc></url></urlset>");
  assert.equal(a.kind, "urlset");
  assert.deepEqual(a.locs, ["https://x.com/a?b=1&c=2", "https://x.com/b"]);
  assert.equal(d.parseSitemap("<sitemapindex><sitemap><loc>https://x.com/s1.xml</loc></sitemap></sitemapindex>").kind, "index");
});

test("robots: our agent group wins over *, longest match wins, Allow beats Disallow on a tie", () => {
  const r = d.parseRobots("User-agent: *\nDisallow: /private\nAllow: /private/ok\n\nUser-agent: CavScope\nDisallow: /nope\n");
  assert.equal(r.allowed("/private/x"), true, "the CavScope group applies, not *");
  assert.equal(r.allowed("/nope/x"), false);
  const s = d.parseRobots("User-agent: *\nDisallow: /private\nAllow: /private/ok\nDisallow: /*.pdf$\n");
  assert.equal(s.allowed("/private/x"), false);
  assert.equal(s.allowed("/private/ok/page"), true);
  assert.equal(s.allowed("/files/a.pdf"), false);
  assert.equal(s.allowed("/files/a.pdf?x=1"), true, "$ anchors the end");
  assert.equal(d.parseRobots("").allowed("/anything"), true);
});

test("page selection: same origin only, de-duplicated, home first, robots respected, capped at 25", () => {
  const robots = d.parseRobots("User-agent: *\nDisallow: /admin\n");
  const candidates = [
    "https://x.com/a", "https://x.com/a/", "https://x.com/a#frag", "https://other.com/b", "https://x.com/admin/panel",
    "mailto:a@x.com", "https://x.com/c?q=1",
  ];
  const r = d.selectPages({ origin: "https://x.com", home: "https://x.com/", candidates, robots });
  assert.deepEqual(r.pages, ["https://x.com/", "https://x.com/a", "https://x.com/c?q=1"]);
  assert.deepEqual(r.skippedByRobots, ["https://x.com/admin/panel"]);
  const many = Array.from({ length: 60 }, (_, i) => `https://x.com/p${i}`);
  assert.equal(d.selectPages({ origin: "https://x.com", home: "https://x.com/", candidates: many }).pages.length, 25);
  assert.equal(d.MAX_PAGES, 25);
});

test("registrable domain: simple, www, multi-part suffixes, IPs, localhost", () => {
  assert.equal(h.registrableDomain("www.aftertoday.agency"), "aftertoday.agency");
  assert.equal(h.registrableDomain("a.b.example.co.uk"), "example.co.uk");
  assert.equal(h.registrableDomain("hpsd.k12.pa.us"), "hpsd.k12.pa.us");
  assert.equal(h.registrableDomain("www.hpsd.k12.pa.us"), "hpsd.k12.pa.us");
  assert.equal(h.registrableDomain("127.0.0.1"), "127.0.0.1");
  assert.equal(h.registrableDomain("localhost"), "localhost");
  assert.equal(h.isFirstParty("cdn.aftertoday.agency", "www.aftertoday.agency"), true);
  assert.equal(h.isFirstParty("cdn.other.com", "www.aftertoday.agency"), false);
});

test("trackers: known cookie names and hosts, and not look-alikes", () => {
  for (const n of ["_ga", "_ga_ABC123", "_gid", "_gcl_au", "_fbp", "_hjSessionUser_1", "__utma", "_clck"]) assert.ok(h.isTrackerCookie(n), n);
  for (const n of ["session", "csrftoken", "cart", "galaxy", "_gallery", "theme"]) assert.ok(!h.isTrackerCookie(n), n);
  assert.ok(h.isTrackerHost("www.googletagmanager.com"));
  assert.ok(h.isTrackerHost("connect.facebook.net"));
  assert.ok(!h.isTrackerHost("fonts.googleapis.com"), "a font host is third-party but not a tracker");
  assert.ok(!h.isTrackerHost("supabase.co"));
});

test("DNS provider names from NS records (OPS-002)", () => {
  assert.deepEqual(h.dnsProvider(["dns1.registrar-servers.com", "dns2.registrar-servers.com"]), ["Namecheap"]);
  assert.deepEqual(h.dnsProvider(["ns1.vercel-dns.com"]), ["Vercel DNS"]);
  assert.deepEqual(h.dnsProvider(["lara.ns.cloudflare.com"]), ["Cloudflare"]);
  assert.deepEqual(h.dnsProvider(["ns-123.awsdns-45.org"]), ["Amazon Route 53"]);
  assert.deepEqual(h.dnsProvider(["ns57.domaincontrol.com"]), ["GoDaddy"]);
  assert.deepEqual(h.dnsProvider(["ns1.wixdns.net"]), ["Wix"]);
  assert.deepEqual(h.dnsProvider(["ns1.unknown-host.net"]), []);
});

// @ts-ignore
import { waitForDeploy } from "../../workers/browser-scan/lib/deploy-wait.mjs";

test("OPS-001: waits for the marker, polling every 5 s up to 3 minutes, bypassing a URL-keyed cache", async () => {
  let t = 0; const urls: string[] = []; const sleeps: number[] = [];
  const res = await waitForDeploy({
    url: "https://x.test/", marker: "build-42", now: () => t, sleep: async (ms: number) => { sleeps.push(ms); t += ms; },
    fetchImpl: async (u: string) => { urls.push(u); return { ok: true, status: 200, text: async () => (urls.length >= 4 ? "<html>build-42</html>" : "<html>build-41</html>"), headers: new Map() }; },
  });
  assert.equal(res.ok, true);
  assert.equal(res.attempts, 4);
  assert.deepEqual(sleeps, [5000, 5000, 5000]);
  assert.ok(new Set(urls).size === 4, "each poll uses a distinct URL, so a cache keyed on the URL cannot serve the old page");
});

test("OPS-001: gives up after 3 minutes and says so; a header can be the marker; nothing to wait for returns at once", async () => {
  let t = 0;
  const never = await waitForDeploy({ url: "https://x.test/", marker: "new", now: () => t, sleep: async (ms: number) => { t += ms; }, fetchImpl: async () => ({ ok: true, status: 200, text: async () => "old", headers: new Map() }) });
  assert.equal(never.ok, false);
  assert.match(never.reason, /did not appear within 180 s \(last: HTTP 200, marker absent\)/);
  assert.ok(never.ms <= 180_000);
  const hdr = await waitForDeploy({ url: "https://x.test/", header: "x-build", headerValue: "42", now: () => t, sleep: async () => {}, fetchImpl: async () => ({ ok: true, status: 200, text: async () => "", headers: { get: () => "42" } }) });
  assert.equal(hdr.ok, true);
  assert.equal((await waitForDeploy({ url: "https://x.test/" })).waited, false);
});
