// The report is a template emitted by Postgres, and every page renders it.
//
//   node --experimental-strip-types --test tests/sitrep/report-template.test.ts
//
// What went wrong: the workspace's two reports -- Plain English for the client,
// Board & Committee for leadership -- were demo scaffolds with hardcoded copy, a
// different header each, and in a signed-in workspace a single live panel dropped
// under each. Two documents of two shapes from one scan, neither matching what the
// tenant reads at /sitrep, and the client report printed as a blank page because
// its print rule named an id that did not exist.
//
// Migration 20260925200050 (muster_109) moved the template into SQL: `sections.report`
// carries the header, the metrics, control coverage, the section list each profile
// shows, and the disclaimer. app.html walks a profile's list; it never decides what
// a report contains. What is pinned here is the contract between the three:
//
//   1. every section a profile names is a key the generator writes;
//   2. app.html has a renderer for every such key (a key it cannot draw renders
//      as a visible notice, but the template must not rely on that);
//   3. the demo fixture declares the same profiles as SQL, so a prospect sees the
//      same document shape a customer gets;
//   4. the print rule names ids that exist, and only the open report prints;
//   5. Controls, added to the markdown in 109, is rendered by sitrep.html and by
//      the board profile, per the rule that a section added to one is added to all.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const migrationsDir = join(repoRoot, "supabase", "migrations");
const app = readFileSync(join(repoRoot, "app.html"), "utf8");
const viewer = readFileSync(join(repoRoot, "sitrep.html"), "utf8");

const newestDefining = (re: RegExp) => {
  const files = readdirSync(migrationsDir).filter((f) => f.endsWith(".sql"))
    .filter((f) => re.test(readFileSync(join(migrationsDir, f), "utf8"))).sort();
  assert.ok(files.length, `no migration matches ${re}`);
  return readFileSync(join(migrationsDir, files[files.length - 1]), "utf8");
};

const modelSql = (() => {
  const sql = newestDefining(/create or replace function muster\.sitrep_report_model/i);
  const at = sql.indexOf("create or replace function muster.sitrep_report_model");
  return sql.slice(at, sql.indexOf("$$;", sql.indexOf("as $$", at) + 5));
})();
const generatorSql = (() => {
  const sql = newestDefining(/create or replace function muster\.generate_sitrep/i);
  const at = sql.indexOf("create or replace function muster.generate_sitrep");
  return sql.slice(at, sql.indexOf("$function$;", at));
})();

/** profile name -> section keys, as SQL declares them. */
function sqlProfiles(): Record<string, string[]> {
  const out: Record<string, string[]> = {};
  const re = /'(client|board)', jsonb_build_object\([\s\S]*?'sections', jsonb_build_array\(([^)]*)\)/g;
  for (const m of modelSql.matchAll(re)) {
    out[m[1]] = [...m[2].matchAll(/'([a-z_]+)'/g)].map((x) => x[1]);
  }
  return out;
}

/** Keys the generator writes under sections, plus keys the report model carries. */
function payloadKeys(): Set<string> {
  const keys = new Set<string>();
  const build = generatorSql.slice(generatorSql.indexOf("v_sections := jsonb_build_object("), generatorSql.indexOf("'evidence_index', v_evidx"));
  for (const m of build.matchAll(/^\s*'([a-z_]+)', /gm)) keys.add(m[1]);
  keys.add("evidence_index");
  const model = modelSql.slice(modelSql.indexOf("return jsonb_build_object("));
  for (const m of model.matchAll(/^\s{4}'([a-z_]+)', /gm)) keys.add(m[1]);
  return keys;
}

test("SQL declares both profiles, each with at least one section", () => {
  const p = sqlProfiles();
  assert.deepEqual(Object.keys(p).sort(), ["board", "client"]);
  for (const [name, keys] of Object.entries(p)) assert.ok(keys.length > 0, `${name} has no sections`);
});

test("every section a profile names is a key the payload carries", () => {
  const keys = payloadKeys();
  for (const [name, list] of Object.entries(sqlProfiles())) {
    for (const k of list) assert.ok(keys.has(k), `profile ${name} names '${k}', which neither the generator nor the report model writes`);
  }
});

test("app.html renders every section the template can name", () => {
  const renderer = app.slice(app.indexOf("function renderReportSection(key, ctx) {"), app.indexOf("function renderReportJurisdiction(j) {"));
  const cases = new Set([...renderer.matchAll(/case '([a-z_]+)'/g)].map((m) => m[1]));
  for (const [name, list] of Object.entries(sqlProfiles())) {
    for (const k of list) assert.ok(cases.has(k), `profile ${name} names '${k}' and app.html has no case for it`);
  }
  // A key the template names and this page cannot draw is a visible notice, not a gap.
  assert.match(renderer, /default:[\s\S]*rd-missing/);
});

test("the demo fixture declares the same profiles as SQL", () => {
  const fixture = app.slice(app.indexOf("const SAMPLE_SITREP = {"));
  const sql = sqlProfiles();
  for (const name of Object.keys(sql)) {
    const m = new RegExp(`${name}: \\{[^}]*sections: \\[([^\\]]*)\\]`).exec(fixture);
    assert.ok(m, `SAMPLE_SITREP has no ${name} profile`);
    const keys = [...m[1].matchAll(/'([a-z_]+)'/g)].map((x) => x[1]);
    assert.deepEqual(keys, sql[name], `SAMPLE_SITREP.${name}.sections differs from SQL`);
  }
});

test("the print rule names ids that exist, and only the open report prints", () => {
  const print = app.slice(app.indexOf("@media print {"), app.indexOf("}\n\n", app.indexOf("@media print {")));
  const rule = /#([a-zA-Z]+)\.view\.active, #([a-zA-Z]+)\.view\.active \{ display: block !important; \}/.exec(print);
  assert.ok(rule, "no print rule for the two report views");
  for (const id of [rule[1], rule[2]]) {
    assert.ok(app.includes(`<section id="${id}" class="view">`), `print rule names #${id}, which is not a view`);
  }
  // The defect: a rule for an id that has never existed. The CSS comment above
  // the rule names it as history, so only a selector counts.
  assert.doesNotMatch(print, /#plainReportView\.view/);
  // Workspace-only controls inside the document never print.
  assert.match(print, /\.no-print[^{]*\{ display: none !important; \}/);
});

test("the reports carry the brand in their own header and footer, not by id-poking", () => {
  assert.match(app, /renderReports\(\);\n\s*\}/, "applyBrandToUI must re-render the reports");
  assert.doesNotMatch(app, /id="plainReportDemoBlocks"|id="boardDemoBlocks"|id="plainSummaryText"|id="boardHeroHeadline"/,
    "a demo scaffold survived; the reports must render from the payload only");
  assert.match(app, /brand\.mode === 'white-label'/);
});

test("Controls is in the markdown, the viewer and the board profile", () => {
  assert.match(generatorSql, /## Controls/);
  assert.match(generatorSql, /not an audit opinion/);
  assert.match(viewer, /report\.controls/);
  assert.match(viewer, />Controls<\/h2>/);
  assert.ok(sqlProfiles().board.includes("controls"), "the board profile does not show Controls");
});

test("the disclaimer is written once, in SQL, and both pages read it", () => {
  assert.match(modelSql, /'disclaimer', 'MUSTER''s SITREP is a technical assessment/);
  assert.match(viewer, /report\.disclaimer \|\| DEFAULT_DISCLAIMER/);
  assert.match(app, /escapeHtml\(r\.disclaimer \|\| ''\)/);
});

test("neither renderer prints 'clear' or 'compliant' as a verdict on a law", () => {
  const appJur = app.slice(app.indexOf("function renderReportJurisdiction(j) {"), app.indexOf("// end renderReportJurisdiction"));
  const strings = appJur.match(/>[^<`$]*</g) || [];
  for (const s of strings) assert.doesNotMatch(s, /\b(clear|compliant)\b/i, `verdict word in app.html jurisdiction renderer: ${s}`);
});
