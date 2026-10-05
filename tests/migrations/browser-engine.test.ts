// The browser engine's database half, pinned from the migration files: every browser rule ships inactive,
// the existing HTTP-engine functions are scoped to their own engine, control scoring cannot read an
// unrun engine as a pass, active tests are gated, and engine RPCs are not callable by browsers.
//
//   node --experimental-strip-types --test tests/migrations/browser-engine.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const dir = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "supabase", "migrations");
const files = readdirSync(dir).filter((f) => f.includes("browser_engine")).sort();
const sql = Object.fromEntries(files.map((f) => [f.replace(/^\d+_/, "").replace(/\.sql$/, ""), readFileSync(join(dir, f), "utf8")]));
const foundation = sql["browser_engine_foundation"];
const guards = sql["browser_engine_active_test_guards"];
const support = sql["browser_engine_support_functions"];
const strip = (s: string) => s.replace(/--.*$/gm, "");

test("three migrations exist, named for the versions the database assigned", () => {
  assert.equal(files.length, 3, files.join(", "));
  assert.ok(foundation && guards && support);
});

test("every browser rule is inserted INACTIVE, and none is activated here", () => {
  const body = strip(foundation).slice(strip(foundation).indexOf("insert into cavscope.scan_rules"));
  const rows = [...body.matchAll(/^\('([A-Z0-9-]+)'/gm)].map((m) => m[1]);
  assert.deepEqual(rows.sort(), ["A11Y-008", "A11Y-009", "A11Y-010", "FORM-001", "FORM-002", "FORM-003", "FORM-010", "FORM-011", "PRIV-006", "SEC-021", "SEC-022", "TP-002"]);
  assert.equal((body.match(/, false\)/g) ?? []).length, 12, "all twelve end in active = false");
  assert.ok(!/active\s*=\s*true|set active/i.test(strip(foundation)), "nothing activates a rule");
  assert.equal((body.match(/'browser'/g) ?? []).length, 12, "all are check_type browser");
});

test("no proposed ID reuses an existing one, and the A11Y range continues after 007", () => {
  const existing = readdirSync(dir).filter((f) => !f.includes("browser_engine")).map((f) => readFileSync(join(dir, f), "utf8")).join("\n");
  for (const id of ["A11Y-008", "A11Y-009", "A11Y-010", "TP-002", "PRIV-006", "SEC-021", "SEC-022", "FORM-001", "FORM-002", "FORM-003", "FORM-010", "FORM-011"])
    assert.ok(!new RegExp(`\\('${id}'`).test(existing), `${id} is not defined by an earlier migration`);
});

test("the flags ship dark, with enforcement stated because this migration adds the code that reads them", () => {
  assert.match(foundation, /'browser_engine'[\s\S]*?'platform', false, true,[\s\S]*?array\['sql'\]\)/);
  assert.match(foundation, /'browser_active_tests'[\s\S]*?'platform', false, true,[\s\S]*?array\['sql'\]\)/);
});

test("the HTTP engine's functions are scoped to their own engine, each edit asserted to apply exactly once", () => {
  assert.match(foundation, /create or replace function pg_temp\.sub/);
  assert.match(foundation, /pattern not unique/);
  assert.match(foundation, /s\.engine = 'http_native'/);
  assert.match(foundation, /x\.engine = 'http_native'/);
  assert.match(foundation, /engine = 'http_native' and status in \('queued','running'\) order by created_at desc limit 1/);
  assert.match(foundation, /case v_scan\.engine when 'browser' then 'browser' else 'http_native' end/, "reconcile resolves only the scan's own rule family");
  assert.match(foundation, /where id = v_scan\.website_id and v_scan\.engine = 'http_native'/, "a browser scan never overwrites the detected jurisdiction");
});

test("control scoring: a browser rule counts as assessed only where a browser scan has completed", () => {
  assert.match(foundation, /has_browser as/);
  assert.match(foundation, /filter \(where r\.check_type <> 'browser' or hb\.b\)/);
  assert.match(foundation, /when s\.assessed_rules is null then 'not_assessed'/);
});

test("active tests: executive-only grant on a verified site, an unauthorized request is not an error, and the daily limit is 3", () => {
  assert.match(foundation, /org_role\(v_org\) is distinct from 'executive'/);
  assert.match(foundation, /verify ownership of this site before authorizing active tests/);
  assert.match(foundation, /cavscope\.site_host\(w\.url\)/);
  assert.match(foundation, /active_tests_requested/);
  assert.match(guards, /\) >= 3 then/);
  assert.match(guards, /daily limit of 3 per domain/);
  assert.match(guards, /cavscope_set_scan_authorization_hosts/);
  assert.match(guards, /endpoint_hosts/);
});

test("engine RPCs and internals are revoked from browsers by name; only service_role can claim", () => {
  assert.match(foundation, /revoke all on function public\.cavscope_engine_claim_browser\(bigint, integer\) from public, anon, authenticated;/);
  assert.match(foundation, /grant execute on function public\.cavscope_engine_claim_browser\(bigint, integer\) to service_role;/);
  assert.match(foundation, /revoke all on function cavscope\.engine_claim_browser/);
  assert.match(support, /revoke all on function public\.cavscope_engine_open_browser_findings\(bigint\) from public, anon, authenticated;/);
  assert.match(support, /grant execute on function public\.cavscope_engine_open_browser_findings\(bigint\) to service_role;/);
  assert.match(foundation, /revoke all on cavscope\.scan_authorizations from anon, authenticated, public;/);
  assert.match(foundation, /alter table cavscope\.scan_authorizations enable row level security;/);
});

test("the report: title carries the scanned host (REPORT-001), scope text depends on which engines ran, results are listed", () => {
  assert.match(foundation, /cavscope\.sitrep_title\(v\.website_name, v\.target_url\)/);
  assert.match(foundation, /create or replace function cavscope\.sitrep_title/);
  assert.match(foundation, /if cavscope\.sitrep_browser_scan\(p_scan_id\) is not null then/);
  assert.match(foundation, /It does not execute JavaScript, so anything a page builds in the browser after load is not assessed\./, "the sentence stays for scans where no browser engine ran");
  assert.match(foundation, /did not test with a screen reader, keyboard navigation[\s\S]*Core Web Vitals[\s\S]*broken links across the whole site[\s\S]*SPF and DKIM discovery/);
  assert.match(foundation, /zoom or reflow at 200 to 400 percent/);
  assert.match(foundation, /not a statement that the site is secure or accessible/);
  assert.doesNotMatch(strip(foundation), /\bcompliant\b/i, "no rule or report text claims compliance");
});

test("OPS-002: DNS fix notes name the provider, only on DNS-type rules, only from a browser scan's NS evidence", () => {
  assert.match(support, /p_rule_id like 'EMAIL-%' or p_rule_id in \('SEC-015', 'SEC-020'\)/);
  assert.match(support, /DNS for this domain is managed at/);
  assert.match(support, /kind = 'dns_ns'/);
  assert.match(support, /cavscope\.dns_fix_note\(fi\.website_id, r\.rule_id\) as remediation/);
});

test("rule text never claims compliance or a legal conclusion", () => {
  const rules = strip(foundation).slice(strip(foundation).indexOf("insert into cavscope.scan_rules"));
  // "violation" is axe-core's own word for a failed rule; what must never appear is a legal conclusion.
  assert.doesNotMatch(rules, /\b(illegal|unlawful|in compliance|compliant with|violates? (the )?(law|act|statute|regulation)|violation of (the )?(law|act|statute|regulation))\b/i);
  assert.match(rules, /not legal advice/);
});
