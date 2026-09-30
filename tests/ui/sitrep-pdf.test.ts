// SITREP PDF export in admin.html: client-facing and company profiles.
//
//   node --experimental-strip-types --test tests/ui/sitrep-pdf.test.ts

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const html = readFileSync(join(repoRoot, "admin.html"), "utf8");
const app = readFileSync(join(repoRoot, "app.html"), "utf8");
const pdf = html.slice(html.indexOf("// ---- SITREP PDF"), html.indexOf("// The SITREP is generated as markdown"));

test("both profiles have a button and a handler", () => {
  for (const p of ["client", "board"]) {
    assert.match(html, new RegExp(`data-act="sitrep-pdf-${p}"`));
    assert.match(html, new RegExp(`kind === 'sitrep-pdf-${p}'\\) \\{ downloadSitrepPdf\\('${p}'\\)`));
  }
});

test("the PDF walks the template's profile, and every section it can name has a case", () => {
  assert.match(pdf, /r\.profiles\[profile\]/);
  assert.match(pdf, /\(p\.sections \|\| \[\]\)\.map/);
  const mine = new Set([...pdf.matchAll(/case '([a-z_]+)'/g)].map((m) => m[1]));
  const theirs = app.slice(app.indexOf("function renderReportSection(key, ctx) {"), app.indexOf("function renderReportJurisdiction(j) {"));
  for (const m of theirs.matchAll(/case '([a-z_]+)'/g)) assert.ok(mine.has(m[1]), `app.html draws '${m[1]}' and the PDF does not`);
  assert.match(pdf, /default:[\s\S]*class="missing"/);
});

test("a report from before the template is refused, not printed empty", () => {
  assert.match(pdf, /generated before the report template existed/);
  assert.match(pdf, /if \(out\.error\) \{ flash\('bad', out\.error\)/);
});

test("the law section never says clear or compliant as a verdict", () => {
  const j = pdf.slice(pdf.indexOf("function pdfJurisdiction"), pdf.indexOf("function pdfSection"));
  assert.match(j, /l\.assessment === 'no_open_findings'/);
  assert.doesNotMatch(j, /l\.status/);
  assert.doesNotMatch(j, />\s*(Clear|Compliant)\s*</i);
  assert.match(j, /not a determination of compliance/);
});

test("no library, no popup: hidden srcdoc iframe", () => {
  const code = pdf.replace(/^\s*\/\/.*$/gm, "");
  assert.match(code, /f\.srcdoc = out\.html/);
  assert.doesNotMatch(code, /window\.open|<script|https?:\/\/cdn/);
});

test("report text is always escaped: no raw field reaches the document", () => {
  const code = pdf.replace(/^\s*\/\/.*$/gm, "");
  for (const field of ["c.text", "i.text", "x.title", "x.detail", "x.remediation", "e.url", "h.title", "r.disclaimer", "j.disclaimer", "l.summary"]) {
    assert.doesNotMatch(code, new RegExp("\\$\\{" + field.replace(".", "\\.") + "\\}"), field + " interpolated raw");
  }
});

test("Markdown and JSON exports are wired and export the stored payload untouched", () => {
  for (const k of ["md", "json"]) {
    assert.match(html, new RegExp(`data-act="sitrep-export-${k}"`));
    assert.match(html, new RegExp(`kind === 'sitrep-export-${k}'\\) \\{ saveSitrepFile\\('${k}'\\)`));
  }
  const fn = html.slice(html.indexOf("function saveSitrepFile"), html.indexOf("function downloadSitrepPdf"));
  assert.match(fn, /text = r\.content_md;/);
  assert.match(fn, /JSON\.stringify\(r, null, 2\)/);
  assert.match(fn, /revokeObjectURL/);
  assert.match(fn, /replace\(\/\[\^a-z0-9\.-\]\+\/gi/);
});
