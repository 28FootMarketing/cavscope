// The Findings Glossary is read from the rule catalogue, not typed, and it is honest about what scans check.
//
//   node --experimental-strip-types --test tests/ui/glossary.test.ts

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const read = (p: string) => readFileSync(join(root, p), "utf8");
const app = read("app.html");
const migDir = join(root, "supabase", "migrations");
const sql = readdirSync(migDir).filter((f) => f.includes("finding_glossary") || f.includes("scan_rule_text_cavscope")).map((f) => readFileSync(join(migDir, f), "utf8")).join("\n");

const fnBlock = (name: string) => { const i = app.indexOf(`function ${name}(`); assert.ok(i > 0, `${name} exists`); return app.slice(i, i + 3500); };

test("the workspace has a Findings Glossary view and a nav item that opens it", () => {
  assert.match(app, /<section id="glossary" class="view">/);
  assert.match(app, /<button data-view="glossary" data-tooltip="[^"]+">/);
  assert.match(app, /if \(viewId === 'glossary'\) loadGlossary\(\);/);
});

test("it is read from the catalogue through the RPC, with no rule written into the page", () => {
  assert.match(fnBlock("loadGlossary"), /Live\.rpc\('cavscope_finding_glossary'\)/);
  const glossaryCode = app.slice(app.indexOf("// ---- Findings Glossary"), app.indexOf("function toggleSidebar()"));
  assert.ok(!/\b(SEC|EMAIL|AUTH|A11Y|AVAIL|GOV|PRIV|TP)-\d{3}\b/.test(glossaryCode), "no rule id is hardcoded in the glossary code");
});

test("the RPC is a plain read: no framework refs, retired rules excluded, active shown as 'checked'", () => {
  assert.match(sql, /create or replace function public\.cavscope_finding_glossary\(\)/);
  assert.match(sql, /'checked', r\.active/);
  assert.match(sql, /where r\.retired_at is null/);
  const body = sql.slice(sql.indexOf("create or replace function public.cavscope_finding_glossary"), sql.indexOf("revoke all on function public.cavscope_finding_glossary"));
  assert.ok(!/framework_refs/.test(body.replace(/--.*$/gm, "")), "citations are not returned");
  assert.match(sql, /grant execute on function public\.cavscope_finding_glossary\(\) to anon, authenticated, service_role;/);
});

test("a rule scans do not run today is labelled so, never presented as a check", () => {
  assert.match(app, /Not currently checked/);
  assert.match(app, /r\.checked \? '' :/);
});

test("the page says what a clean scan does and does not mean", () => {
  assert.match(app, /It does not mean a site is secure/);
});

test("items collapse one open at a time, and the filters are a pick-list and a search", () => {
  assert.match(app, /data-acc-group="glossary-cat"/);
  assert.match(app, /data-acc-group="glossary-rule"/);
  assert.match(app, /<select id="glossarySeverity"/);
  assert.match(app, /id="glossarySearch"[^>]*data-tooltip=/);
});

test("the old product name is gone from the rule text a customer reads", () => {
  assert.match(sql, /where rule_id in \('AUTH-004', 'AVAIL-003', 'AVAIL-004'\)/);
  assert.match(sql, /'MUSTER-Scanner', 'CavScope-Scanner'/);
  assert.match(read("supabase/functions/cavscope-scan/index.ts"), /CavScope-Scanner\/1\.0/);
});

test("the SQL that writes tenant-visible text no longer says the old name", () => {
  const f = readdirSync(migDir).find((n) => n.includes("customer_visible_muster_text_functions"))!;
  const s = readFileSync(join(migDir, f), "utf8");
  assert.match(s, /replace\(pg_get_functiondef\(r\.oid\), 'MUSTER', 'CavScope'\)/);
  assert.match(s, /expected 8 functions/);
  const c = readFileSync(join(migDir, readdirSync(migDir).find((n) => n.includes("customer_visible_muster_text_controls"))!), "utf8");
  assert.match(c, /update cavscope\.controls set description = replace\(description, 'MUSTER', 'CavScope'\)/);
});
