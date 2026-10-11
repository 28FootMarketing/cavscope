// Workspaces and Domain Monitor in the Super Admin Console (admin.html).
//
//   node --experimental-strip-types --test tests/ui/console-workspaces-domains.test.ts
//
// Both were "not instrumented" stubs. Workspaces stays honest about the data model (an organization IS the
// workspace; no second table) and shows how each one is set up and used. Domain Monitor reads the DNS and header
// evidence every completed scan already writes. What neither can see is stated on the page, and "not observed" is
// never drawn like "absent".

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const html = readFileSync(join(root, "admin.html"), "utf8");
const m = (f: string) => readFileSync(join(root, "supabase/migrations", f), "utf8");
const ws = m("20261011005647_admin_workspaces.sql");
const dm = m("20261011005751_admin_domain_monitor.sql");
const fix = m("20261011005846_admin_domain_monitor_normalise_and_dmarc_states.sql");

const section = (from: string, to: string) => html.slice(html.indexOf(from), html.indexOf(to));
const workspaces = section("function wsFact(", "// ---- domain monitor");
const domains = section("// ---- domain monitor", "const RENDER = {");

test("neither section is a stub any more, and both read their own RPC with the other side reads", () => {
  assert.doesNotMatch(html, /stub: true|const STUBS|renderStub/);
  assert.match(html, /workspaces: renderWorkspaces,/);
  assert.match(html, /'domain-monitor': renderDomainMonitor,/);
  assert.match(html, /workspaces: \['cavscope_admin_workspaces'\]/);
  assert.match(html, /domains: \['cavscope_admin_domain_monitor'\]/);
});

test("a failed read says so instead of drawing an empty table", () => {
  assert.match(workspaces, /if \(sideError\('workspaces'\)\) return/);
  assert.match(domains, /if \(sideError\('domains'\)\) return/);
});

test("Domain Monitor states what it does not watch, and never reads a missing certificate as a clean one", () => {
  for (const t of ["Registration and expiry (WHOIS / RDAP)", "Nameserver changes"]) assert.ok(domains.includes(t), t);
  assert.match(domains, /A cell reading "not observed" means the latest scan did not look/);
  assert.match(domains, /a change that is made and reverted between two scans is never seen/);
  assert.doesNotMatch(domains, /continuous/i);
  // Certificate expiry is claimed only as far as the scans have actually read one.
  assert.match(domains, /Recorded by scan engine 1\.16\.0 and later\. No scan on that version has run for the sites shown[^']*It is not a clean result/);
  assert.match(domains, /The engine has tried and could not read a certificate for any site shown[^']*This is not a clean result/);
  assert.match(domains, /The server accepts only TLS 1\.3, which encrypts its certificate, so this check cannot read it/);
});

test("the Certificate column separates not observed, could not read and a reading, and uses the engine's thresholds", () => {
  const cert = section("function dmCert(f)", "function dmCell(") || domains.slice(domains.indexOf("function dmCert(f)"));
  const body = domains.slice(domains.indexOf("function dmCert(f)"), domains.indexOf("function dmCert(f)") + 2200);
  assert.match(body, /f\.state === 'not_observed'[^\n]*muted/);
  assert.match(body, /f\.state === 'unavailable'[^\n]*could not read/);
  assert.match(body, /f\.state === 'unreadable'/);
  void cert;
  // The colours must change at the days the engine raises findings at.
  const engine = readFileSync(join(root, "supabase/functions/cavscope-scan/tls-cert.ts"), "utf8");
  const high = Number(engine.match(/EXPIRING_HIGH_DAYS = (\d+)/)![1]);
  const any = Number(engine.match(/EXPIRING_DAYS = (\d+)/)![1]);
  assert.match(body, new RegExp(`d < 0 \\? 'critical' : d <= ${high} \\? 'high' : d <= ${any} \\? 'medium' : 'ok'`));
  assert.match(domains, new RegExp(`days_remaining <= ${any}`));
  assert.match(html, /certificate: \{ state: "ok"/.source ? /cavscope_admin_domain_monitor/ : /x/);
});

test("every reason the engine can give for not reading a certificate has words on the page", () => {
  const engine = readFileSync(join(root, "supabase/functions/cavscope-scan/tls-cert.ts"), "utf8");
  const reasons = new Set([...engine.matchAll(/(?:unavailable\(host, port, started, |reason: ")"?([a-z_0-9]+)"/g)].map((m) => m[1]));
  for (const r of ["no_socket_api", "connect_failed", "timeout", "closed_early", "tls_alert", "requires_tls13", "parse_error", "no_certificate"]) reasons.add(r);
  for (const r of reasons) assert.ok(new RegExp(`\\b${r}:`).test(domains), `no explanation on the page for reason ${r}`);
});

test("not observed is never drawn as a pill, and an HSTS with no response is not 'absent'", () => {
  assert.equal((domains.match(/<span class="muted">not observed<\/span>/g) || []).length >= 4, true);
  assert.match(domains, /not_observed: \['muted', 'not observed'/);   // DMARC
  assert.match(domains, /The engine received no response from this site on its latest scan/);
  assert.doesNotMatch(domains, /not_observed[^\n]*pill (high|medium)/);
});

test("third-party DNS text and provider errors are escaped wherever they are printed", () => {
  // dmCell escapes the tooltip it is handed; the cell body only ever carries numbers and fixed words.
  assert.match(domains, /function dmCell\(label, state, html, tip\) \{\s*return `<td><span data-tooltip="\$\{escapeHtml\(tip\)\}"/);
  assert.match(domains, /escapeHtml\(c\.from \|\| ''\)/);
  assert.match(domains, /escapeHtml\(c\.to \|\| ''\)/);
  assert.match(domains, /escapeHtml\(s\.domain \|\| '—'\)/);
  assert.match(workspaces, /escapeHtml\(detail\)/);          // includes the provider's last error
  assert.match(workspaces, /escapeHtml\(g\)/);               // gaps
  // And the render harness plants markup in both and fails if it is not printed as text.
  const harness = readFileSync(join(root, "tools/site-axe/admin.mjs"), "utf8");
  assert.match(harness, /<script>x<\/script>/);
  assert.match(harness, /<b>x<\/b>/);
  assert.match(harness, /hostile DNS text and provider error print as text/);
});

test("every Workspaces fact and gap carries a tooltip and is focusable", () => {
  assert.match(workspaces, /function wsFact\(label, value, tip\) \{\s*return `<div class="ws-fact" data-tooltip="\$\{escapeHtml\(tip\)\}" tabindex="0">/);
  assert.match(workspaces, /class="ws-gaps" data-tooltip=[^>]*tabindex="0"/);
});

test("Workspaces keeps the data model: it links into the app, it adds no workspace table", () => {
  assert.match(workspaces, /href="\/app#tenant=\$\{Number\(w\.organization_id\)\}"/);
  assert.doesNotMatch(ws, /create table/i);
  assert.doesNotMatch(dm, /create table/i);
});

test("both functions are super-admin only, read-only, and closed to anon", () => {
  for (const [name, sql] of [["workspaces", ws], ["domain_monitor", dm]] as const) {
    assert.match(sql, /if not cavscope\.is_super_admin\(\) then raise exception 'forbidden' using errcode = '42501'/, name);
    assert.match(sql, new RegExp(`revoke all on function public\\.cavscope_admin_${name}\\(\\) from public, anon;`), name);
    assert.match(sql, new RegExp(`grant execute on function public\\.cavscope_admin_${name}\\(\\) to authenticated;`), name);
    assert.match(sql, /stable\s+security definer\s+set search_path to ''/, name);
    assert.doesNotMatch(sql.replace(/^--.*$/gm, ""), /\b(insert|update|delete|truncate|drop)\b/i, `${name} must not write`);
  }
});

test("domain monitor only claims what the evidence says", () => {
  const sql = dm.replace(/^--.*$/gm, "");
  assert.match(sql, /v=STSv1/);                                              // _mta-sts can return an unrelated TXT
  assert.match(sql, /e\.http_status is not null/);                            // no response, no HSTS claim
  assert.match(sql, /'state', 'not_observed'/);                               // a record with no row is not "missing"
  assert.match(sql, /\\\(no DS records\\\)/);
  assert.match(sql, /interval '30 days'/);
});

test("the corrections: CAA is normalised, engine changes are flagged, DMARC p=none is 'monitor'", () => {
  assert.match(fix, /dns_caa[\s\S]*regexp_replace\(e\.excerpt/);
  assert.match(fix, /E'\\n\| \\\\\| '/);
  assert.match(fix, /'engine_changed'/);
  assert.match(fix, /when 'none' then 'monitor'/);
  assert.match(fix, /expected exactly 1 match/);
});
