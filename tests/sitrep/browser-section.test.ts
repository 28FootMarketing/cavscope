// The browser engine's results are part of the report's data, not only its markdown.
//
//   node --experimental-strip-types --test tests/sitrep/browser-section.test.ts
//
// Migration 20261005020553 put "## Browser Engine Results" in the SITREP markdown and
// nothing else: no sections.browser, no place in the report template, nothing in
// /sitrep or the workspace reports. The markdown and the viewer were different
// documents, which is the failure CLAUDE.md records for the SITREP ("a section added
// to one is added to all"). Migration 20261011032759 closes it. This file pins the
// SQL, runs both pages' real renderers on a payload, and checks they agree.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { finalFunctionSql } from "./patched-sql.ts";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const read = (f: string) => readFileSync(join(root, f), "utf8");
const migration = read("supabase/migrations/20261011032759_browser_results_in_sitrep_sections.sql");
const foundation = read("supabase/migrations/20261005020553_browser_engine_foundation.sql");
const viewer = read("sitrep.html");
const app = read("app.html");

// --- SQL ------------------------------------------------------------------------

test("the section function returns null without a browser scan and is closed to browsers", () => {
  assert.match(migration, /if v_id is null then return null; end if;/);
  assert.match(migration, /revoke all on function cavscope\.sitrep_browser_section\(bigint\) from public, anon, authenticated;/);
});

test("it lists every check in the order the engine wrote them, and carries the unauthorized-active-tests note", () => {
  assert.match(migration, /jsonb_agg\(jsonb_build_object\('rule_id'[^)]*\)[^)]*order by t\.n\)/);
  assert.match(migration, /with ordinality as t\(x, n\)/);
  assert.match(migration, /'active_tests_unauthorized'/);
});

test("the generator stores it before the template is built, and the template names it after top_findings in both profiles", () => {
  const gen = finalFunctionSql("generate_sitrep");
  assert.match(gen, /v_browser := cavscope\.sitrep_browser_section\(p_scan_id\);/);
  assert.match(gen, /'browser', v_browser,/);
  assert.ok(gen.indexOf("v_browser := cavscope.sitrep_browser_section") < gen.indexOf("sitrep_report_model("),
    "the section must exist before sitrep_report_model reads the sections");
  const model = finalFunctionSql("sitrep_report_model");
  assert.equal((model.match(/'top_findings', 'browser'/g) || []).length, 2);
});

test("the edit is guarded against drift and each replacement must match exactly once", () => {
  assert.match(migration, /md5\(pg_get_functiondef\('cavscope\.generate_sitrep\(bigint\)'::regprocedure\)\) <> '[0-9a-f]{32}'/);
  assert.match(migration, /expected exactly one occurrence of/);
});

test("the markdown still prints the section where the profiles put it: after Findings, before Controls", () => {
  const gen = finalFunctionSql("generate_sitrep");
  assert.match(gen, /sitrep_browser_md\(p_scan_id\)/);
  assert.ok(gen.indexOf("## Findings") < gen.indexOf("sitrep_browser_md(p_scan_id)"));
  assert.ok(gen.indexOf("sitrep_browser_md(p_scan_id)") < gen.indexOf("## Controls"));
});

// --- both pages' real renderers --------------------------------------------------

function slice(src: string, start: string, end: string) {
  const a = src.indexOf(start);
  assert.ok(a >= 0, `missing ${start}`);
  return src.slice(a, src.indexOf(end, a) + end.length);
}
const escViewer = slice(viewer, "  function escapeHtml(str) {", "\n  }\n");
const escApp = slice(app, "    function escapeHtml(str) {", "\n    }\n");
// deno-lint-ignore no-explicit-any
const viewerRender = new Function(`${escViewer}\n${slice(viewer, "  function renderBrowser(b) {", "\n  }\n")}\nreturn renderBrowser;`)() as (b: any) => string;
// deno-lint-ignore no-explicit-any
const appRender = new Function("reportWhen", `${escApp}\n${slice(app, "    function renderReportBrowser(b) {", "\n    }\n")}\nreturn renderReportBrowser;`)((x: unknown) => String(x ?? "")) as (b: any) => string;

const payload = {
  scan_id: 250, engine_version: "browser-1.0.0", completed_at: "2026-10-05T03:12:51Z", pages_visited: 3,
  checks: [
    { rule_id: "A11Y-010", outcome: "passed", detail: "No axe violations on 3 pages." },
    { rule_id: "SEC-021", outcome: "finding", detail: "Console error <img src=x onerror=alert(1)> on /" },
    { rule_id: "OPS-001", outcome: "needs_review", detail: "Waited for a deploy marker." },
    { rule_id: "FORM-010", outcome: "skipped", detail: "No authorization on file." },
  ],
  active_tests_unauthorized: true,
};

for (const [name, render] of [["sitrep.html", viewerRender], ["app.html", appRender]] as const) {
  test(`${name} draws nothing for a report with no browser scan`, () => {
    assert.equal(render(null), "");
    assert.equal(render(undefined), "");
    assert.equal(render({}), "");
  });

  test(`${name} lists every check, passes included, and escapes engine text`, () => {
    const out = render(payload);
    for (const c of payload.checks) assert.ok(out.includes(c.rule_id), `${c.rule_id} missing`);
    assert.ok(out.includes("needs review") && out.includes("skipped") && out.includes("passed") && out.includes("finding"));
    assert.ok(!out.includes("<img"), "engine text was not escaped");
    assert.ok(out.includes("&lt;img"));
    assert.match(out, /Pages visited: 3/);
    assert.match(out, /Active tests were requested for this scan but the site has no current authorization on file/);
  });

  test(`${name} never words a pass as the site being secure, accessible or compliant`, () => {
    const out = render(payload);
    assert.match(out, /it is not a statement that the site is secure or accessible/);
    assert.doesNotMatch(out.replace(/it is not a statement that the site is secure or accessible/, ""), /\b(compliant|clear|secure|accessible)\b/i);
  });

  test(`${name} reports an empty check list as exactly that`, () => {
    assert.match(render({ ...payload, checks: [], active_tests_unauthorized: false }), /recorded no checks/);
  });
}

test("the two pages and the markdown say the same thing about what a pass means", () => {
  const sentence = "Every check is listed, including those that passed. A passed check means these checks found nothing on this date; it is not a statement that the site is secure or accessible.";
  assert.ok(foundation.includes(sentence), "the markdown sentence changed");
  assert.ok(viewerRender(payload).includes(sentence));
  assert.ok(appRender(payload).includes(sentence));
});

// --- wiring ----------------------------------------------------------------------

test("the viewer draws it between Findings and Controls, and the workspace has a case for it", () => {
  const body = viewer.slice(viewer.indexOf("function renderSitrep(sitrep) {"));
  assert.ok(body.indexOf("Top Findings") < body.indexOf("renderBrowser(s.browser)"));
  assert.ok(body.indexOf("renderBrowser(s.browser)") < body.indexOf(">Controls</h2>"));
  assert.match(app, /case 'browser':\s*return renderReportBrowser\(s\.browser\);/);
});

test("the demo fixture names the section but carries no browser data", () => {
  const fixture = app.slice(app.indexOf("const SAMPLE_SITREP = {"));
  assert.equal((fixture.match(/'top_findings', 'browser'/g) || []).length, 2);
  assert.doesNotMatch(fixture.slice(0, fixture.indexOf("report: {")), /\bbrowser: \{/);
});
