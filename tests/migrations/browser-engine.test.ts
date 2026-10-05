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

const worker = sql["browser_engine_vercel_worker"];
test("four migrations exist, named for the versions the database assigned", () => {
  assert.equal(files.length, 4, files.join(", "));
  assert.ok(foundation && guards && support && worker);
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

test("Vercel worker RPCs: every one checks the shared secret first, and ingest and fail touch only a RUNNING browser scan", () => {
  for (const fn of ["cavscope_worker_claim_browser", "cavscope_worker_ingest", "cavscope_worker_fail", "cavscope_worker_open_findings"]) {
    const start = worker.indexOf(`function public.${fn}(`);
    assert.ok(start > 0, fn);
    const body = worker.slice(start, worker.indexOf("$$;", worker.indexOf("$$", start) + 2));
    assert.match(body.slice(0, 600), /if not cavscope\.worker_secret_ok\(p_secret\) then raise exception 'forbidden' using errcode = '42501'/, `${fn} checks the secret before anything else`);
  }
  assert.equal((worker.match(/exists \(select 1 from cavscope\.scans where id = p_scan_id and engine = 'browser' and status = 'running'\)/g) ?? []).length, 2, "ingest and fail are narrowed to running browser scans");
  assert.match(worker, /least\(greatest\(coalesce\(p_limit, 1\), 1\), 3\)/, "a caller cannot claim an unbounded batch");
});

test("Vercel worker: the secret lives in Vault, is compared by hash, and the function holds no service-role key", () => {
  assert.match(worker, /vault\.create_secret\(encode\(extensions\.gen_random_bytes\(32\), 'hex'\), 'cavscope_browser_worker_secret'/);
  assert.match(worker, /not exists \(select 1 from vault\.secrets where name = 'cavscope_browser_worker_secret'\)/, "re-running never rotates it");
  assert.match(worker, /extensions\.digest\(d\.decrypted_secret, 'sha256'\)[\s\S]*extensions\.digest\(p_secret, 'sha256'\)/);
  assert.match(worker, /revoke all on function cavscope\.worker_secret_ok\(text\) from public, anon, authenticated;/);
  assert.match(worker, /revoke all on function cavscope\.kick_browser_scan\(bigint\) from public, anon, authenticated;/);
  assert.match(worker, /revoke all on function cavscope\.kick_stale_browser_scans\(\) from public, anon, authenticated;/);
});

test("Vercel worker: anon may execute exactly the four secret-gated wrappers and no engine RPC", () => {
  const grants = [...strip(worker).matchAll(/grant execute on function ([\w.]+)\(/g)].map((m) => m[1]).sort();
  assert.deepEqual(grants, ["public.cavscope_worker_claim_browser", "public.cavscope_worker_fail", "public.cavscope_worker_ingest", "public.cavscope_worker_open_findings"]);
  assert.ok(!/grant execute[^;]*cavscope_engine_/.test(strip(worker)), "no cavscope_engine_* function is opened to anon");
});

test("Vercel worker: a request kicks the function, a failed kick is recorded not raised, and the sweep only fires for a stuck scan", () => {
  assert.match(worker, /https:\/\/cavscope\.28footsystems\.com\/api\/browser-scan/);
  assert.match(worker, /'x-cavscope-worker-secret', v_secret/);
  assert.match(worker, /perform cavscope\.kick_browser_scan\(v_scan_id\);\s+exception when others then[\s\S]*Browser engine kick deferred/);
  assert.match(worker, /status = 'queued' and queued_at < now\(\) - interval '2 minutes'/);
  assert.match(worker, /cron\.schedule\('cavscope-browser-sweep', '\*\/5 \* \* \* \*'/);
  assert.match(worker, /where not exists \(select 1 from cron\.job where jobname = 'cavscope-browser-sweep'\)/);
  assert.doesNotMatch(strip(worker), /muster/i, "no old product name in a new migration");
});
