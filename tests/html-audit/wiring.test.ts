// The HTML audit's wiring: who may use it, and what it keeps.
//
//   node --experimental-strip-types --test tests/html-audit/wiring.test.ts
//
// Super admins only to start, behind the html_audit flag so a workspace can be
// given it later without a deploy (owner, 2026-09-30). The flag claims
// enforcement in 'sql' and 'app'; CLAUDE.md requires a claim to be true in the
// code, so each is checked here. The page and the nav are explanations; the
// gate is cavscope_html_audit_allowed(), which the edge function asks under the
// caller's JWT before it reads the HTML.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const read = (p: string) => readFileSync(join(root, p), "utf8");

const migration = read("supabase/migrations/20260930202245_html_audit_flag.sql");
const fn = read("supabase/functions/cavscope-html-audit/index.ts");
const config = read("supabase/config.toml");
const page = read("html-audit.html");
const app = read("app.html");
const admin = read("admin.html");
const claude = read("CLAUDE.md");

test("the flag is off by default and claims exactly what reads it", () => {
  assert.match(migration, /'html_audit', 'HTML audit'/);
  assert.match(migration, /'organization', false, null, false, 'workspace'/, "off for every organization by default");
  assert.match(migration, /array\['sql', 'app'\]/);
  assert.doesNotMatch(migration, /\bmuster_/, "no new muster_* name");
});

test("sql claim: the gate reads the flag, lets super admins in, and honours the kill switch first", () => {
  const body = migration.slice(migration.indexOf("create or replace function public.cavscope_html_audit_allowed"));
  assert.match(body, /security definer/);
  assert.match(body, /set search_path = ''/);
  assert.match(body, /cavscope\.has_flag\(m\.organization_id, 'html_audit'\)/);
  const kill = body.indexOf("kill_switch"), sup = body.indexOf("is_super_admin()");
  assert.ok(kill > 0 && sup > kill, "a kill switch must stop super admins too");
  assert.match(body, /v_uid is null then return false/, "no identity, no access");
  assert.match(migration, /revoke all on function public\.cavscope_html_audit_allowed\(\) from public, anon;/, "anon revoked by name");
  assert.match(migration, /has_function_privilege\('anon', 'public\.cavscope_html_audit_allowed\(\)'/, "and the migration proves it");
});

test("app claim: the workspace link is shipped hidden and fails closed on the flag", () => {
  assert.match(app, /<a class="nav-out" id="navHtmlAudit" href="\/audit\/html" hidden /);
  assert.match(app, /htmlAuditNav\.hidden = !\(isSuper \|\| \(o\.flags && o\.flags\.html_audit === true\)\)/);
  assert.match(app, /\['navPlatformConsole', 'btnPlatformConsole', 'navHtmlAudit'\]\.forEach\(id => \{ const el = document\.getElementById\(id\); if \(el\) el\.hidden = true; \}\)/,
    "leaving a live workspace hides it again");
  assert.doesNotMatch(app.slice(app.indexOf("navFlagMap: {"), app.indexOf("applyFlagsToNav(flags) {")), /html_audit/,
    "not in navFlagMap, which fails open");
});

test("the edge function checks access before it reads the HTML, under the caller's JWT", () => {
  assert.match(config, /\[functions\.cavscope-html-audit\]\n(#.*\n)*verify_jwt = true/);
  const gate = fn.indexOf('db.rpc("cavscope_html_audit_allowed")');
  const parse = fn.indexOf("JSON.parse(raw)");
  const readBody = fn.indexOf("await req.text()");
  assert.ok(gate > 0 && gate < readBody && readBody < parse, "gate, then read, then parse");
  assert.match(fn, /createClient\(URL_, ANON, \{\s*global: \{ headers: \{ Authorization: authorization \} \}/, "anon key plus the caller's token, never the service role");
  assert.doesNotMatch(fn, /SERVICE_ROLE/);
  assert.match(fn, /if \(gateError \|\| allowed !== true\) return json\(\{ error: "The HTML audit is not turned on for your account\." \}, 403\)/,
    "an anon caller the gate has no grant for is refused with 403, not reported as a fault");
  assert.doesNotMatch(fn, /detail: gateError/, "the refusal does not echo database errors");
});

test("nothing pasted is stored or logged", () => {
  assert.doesNotMatch(fn, /\.from\(|\.insert\(|\.upsert\(|console\.(log|info|error|warn)\(/);
  const rpcs = [...fn.matchAll(/\.rpc\("([^"]+)"/g)].map((m) => m[1]);
  assert.deepEqual(rpcs, ["cavscope_html_audit_allowed"], "the only database call is the gate");
});

test("the one outbound fetch is guarded", () => {
  assert.match(fn, /if \(!isFetchableScriptUrl\(url\)\) return/);
  assert.match(fn, /redirect: "manual"/);
  assert.match(fn, /MAX_SRI_SCRIPTS = 20/);
  assert.match(fn, /MAX_SCRIPT_BYTES = 2_000_000/);
  assert.match(fn, /SCRIPT_TIMEOUT_MS = 5000/);
  assert.match(fn, /const c = bySrc\.get\(src\);\s*if \(!c\)/, "only a script this page names as an SRI candidate is fetched");
});

test("the page follows every standing page rule", () => {
  assert.match(page, /detectSessionInUrl: false/);
  for (const fnName of ["initTooltips()", "initAccordions()", "initContextMenuGuard()"]) assert.ok(page.includes(fnName), fnName);
  assert.match(page, /\.app-tooltip \{/);
  assert.match(page, /cavscope:tokens:start/);
  assert.match(page, /data-acc-group="html-findings"/, "findings open one at a time");
  assert.match(page, /data-acc-group="html-howto"/);
  assert.match(page, /<select id="fxLang" data-draft="lang"/, "the language comes from a list");
  assert.match(page, /forcedPasswordChange\(session\)\) \{ location\.replace\(window\.location\.origin \+ '\/'\)/);
  assert.match(page, /rpc\('cavscope_html_audit_allowed'\)/);
  assert.match(page, /What this audit did not check/, "every result states its scope");
});

test("the page never pre-fills words on the owner's behalf", () => {
  const seed = page.slice(page.indexOf("function seedDefaults"), page.indexOf("// ---------- step 2"));
  for (const k of ["title", "description", "orgName", "privacyUrl", "termsUrl"]) {
    assert.doesNotMatch(seed, new RegExp(`d\\.${k}\\s*=`), `${k} must come from a person`);
  }
  assert.match(seed, /text: ''/, "alt text starts empty");
  assert.match(page, /x\.decorative \? '' : \(x\.text\.trim\(\) \? x\.text : null\)/, "an unanswered image is skipped, not given an empty alt");
});

test("the console links to it, and CLAUDE.md records it", () => {
  assert.match(admin, /href="\/audit\/html"/);
  assert.match(claude, /cavscope-html-audit/);
  assert.match(claude, /html_audit/);
});
