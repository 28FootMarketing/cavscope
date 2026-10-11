// A framework name on a compliance screen is jargon until it is explained, and the
// explanation has to say what a mapping is not.
//
//   node --experimental-strip-types --test tests/ui/framework-tooltips.test.ts
//
// The Controls view (renderControls), the live Laws and Standards panel and the Controls
// table in both reports printed "SOC 2", "GDPR", "ISO 27001" with no tooltip, though every
// page must explain its data points (CLAUDE.md, "Tooltips are mandatory on every page").
// frameworkTip() and controlAssessmentTip() supply the words. They are written once in
// app.html and copied into sitrep.html, so this runs both and fails if they differ.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const app = readFileSync(join(root, "app.html"), "utf8");
const viewer = readFileSync(join(root, "sitrep.html"), "utf8");

/** The source of `function name(...) { ... }`, found by matching braces (no braces occur inside the strings). */
function fn(src: string, header: string) {
  const a = src.indexOf(header);
  assert.ok(a >= 0, `missing ${header}`);
  let depth = 0;
  for (let i = src.indexOf("{", a); i < src.length; i++) {
    if (src[i] === "{") depth++;
    else if (src[i] === "}" && --depth === 0) return src.slice(a, i + 1);
  }
  throw new Error(`unbalanced ${header}`);
}
function load(src: string) {
  const body = `${fn(src, "function frameworkTip(name) {")}\n${fn(src, "function controlAssessmentTip(a) {")}`;
  return new Function(`${body}\nreturn { frameworkTip, controlAssessmentTip };`)() as {
    frameworkTip: (n: unknown) => string; controlAssessmentTip: (a: unknown) => string;
  };
}
const A = load(app);
const V = load(viewer);

const NAMES = ["SOC 2", "SOC 2 (AICPA TSC)", "ISO 27001", "GDPR", "PCI DSS", "PCI_DSS", "WCAG 2.2", "NIST CSF 2.0", "NIST SP 800-53 Rev. 5",
  "OWASP Top 10:2025", "OWASP Secure Headers", "HIPAA", "US", "PA", "Something Added Later", "", null, undefined];

test("the two pages give the same tip for every framework name and every assessment", () => {
  for (const n of NAMES) assert.equal(V.frameworkTip(n), A.frameworkTip(n), `frameworkTip differs for ${String(n)}`);
  for (const a of ["met", "partial", "not_met", "not_assessed", "", null, undefined, "weird"]) {
    assert.equal(V.controlAssessmentTip(a), A.controlAssessmentTip(a), `controlAssessmentTip differs for ${String(a)}`);
  }
});

test("each known framework gets its own sentence, and an unknown one gets the general one, never a guess", () => {
  const general = A.frameworkTip("Something Added Later");
  assert.equal(A.frameworkTip(""), general);
  assert.equal(A.frameworkTip(null), general);
  assert.equal(A.frameworkTip("US"), general, "a jurisdiction code is not a framework");
  const specific = ["SOC 2", "ISO 27001", "GDPR", "PCI DSS", "WCAG 2.2", "NIST CSF 2.0", "NIST SP 800-53 Rev. 5", "OWASP Top 10:2025", "HIPAA"].map((n) => A.frameworkTip(n));
  assert.equal(new Set(specific).size, specific.length, "two frameworks share a tip");
  for (const t of specific) assert.notEqual(t, general);
  assert.equal(A.frameworkTip("PCI_DSS"), A.frameworkTip("PCI DSS"), "stored keys use underscores");
});

test("no tip claims compliance, certification or an opinion; the SOC 2 and ISO tips say who gives those", () => {
  const all = [...NAMES.map((n) => A.frameworkTip(n)), ...["met", "partial", "not_met", "not_assessed"].map((a) => A.controlAssessmentTip(a))];
  for (const t of all) {
    assert.doesNotMatch(t, /\b(is|are|you are|you're) (fully )?(compliant|certified|secure)\b/i, t);
    assert.doesNotMatch(t, /\bclear\b/i, t);
  }
  assert.match(A.frameworkTip("SOC 2"), /licensed CPA firm/);
  assert.match(A.frameworkTip("ISO 27001"), /accredited certification body/);
  assert.match(A.frameworkTip("HIPAA"), /counsel/);
  assert.match(A.controlAssessmentTip("met"), /not proof/);
  assert.match(A.controlAssessmentTip("not_assessed"), /nothing is concluded either way/);
});

test("the Controls view, the laws panel, both reports and the map-control form carry tooltips on framework data", () => {
  const rc = app.slice(app.indexOf("function renderControls() {"), app.indexOf("function renderEvidence() {"));
  assert.match(rc, /data-tooltip="\$\{escapeHtml\(frameworkTip\(c\.framework\)\)\}" tabindex="0">\$\{escapeHtml\(c\.framework\)\}/);
  assert.match(rc, /controlStatusTip\(c\.status\)/);
  const head = app.slice(app.indexOf('<div class="table-header grid-controls">'), app.indexOf('<div id="controlTableBody"'));
  for (const label of ["Framework / Code", "Obligation &amp; Scope|Obligation & Scope", "Owner", "Assessment Status", "Modify"]) {
    assert.match(head, new RegExp(`data-tooltip="[^"]+" tabindex="0">(${label})</span>`), `${label} has no tooltip`);
  }
  assert.match(app, /data-tooltip="[^"]+" tabindex="0">Framework \/ Jurisdiction<\/span>/);
  assert.match(app, /<select name="framework" data-tooltip="/);
  for (const [name, src] of [["app.html", app], ["sitrep.html", viewer]] as const) {
    assert.match(src, /frameworkTip\(i\.framework_label \|\| i\.framework\)/, `${name}: report framework cell`);
    assert.match(src, /controlAssessmentTip\(i\.assessment\)/, `${name}: report assessment chip`);
    assert.match(src, /<th data-tooltip="[^"]+" tabindex="0">Framework<\/th>/, `${name}: report Framework header`);
  }
});

// --- the names in running text ------------------------------------------------------

test("framework names written into prose are tooltip targets that read their words from frameworkTip", () => {
  const spans = [...app.matchAll(/<span class="fw" data-framework="([^"]+)" tabindex="0">([^<]+)<\/span>/g)];
  assert.ok(spans.length >= 12, `expected the Controls hero, banner and principle to be marked up, found ${spans.length}`);
  const general = A.frameworkTip("Something Added Later");
  for (const [, key, label] of spans) {
    assert.notEqual(A.frameworkTip(key), general, `${label} (${key}) falls back to the general sentence`);
  }
  // The explanation is never copied next to the name; the decorator sets it from the one source.
  assert.doesNotMatch(app, /class="fw" data-framework="[^"]+" data-tooltip=/);
  const deco = fn(app, "function decorateFrameworkNames(root) {");
  assert.match(deco, /frameworkTip\(el\.getAttribute\('data-framework'\)\)/);
  assert.ok(app.indexOf("decorateFrameworkNames(); initTooltips();") > 0, "the decorator must run at start, before the tooltip engine");
});

test("the Controls view prose no longer lists bare framework names", () => {
  const hero = app.slice(app.indexOf("<h2>Framework Control Mapping</h2>"), app.indexOf('<div id="controlsDemoBlocks">'));
  const banner = app.slice(app.indexOf("Not a Certification or Legal Opinion"), app.indexOf('<div class="table-header grid-controls">'));
  for (const text of [hero, banner]) {
    // Attributes are not prose (a button's own tooltip may name a framework), so tags go too.
    assert.doesNotMatch(text.replace(/<span class="fw"[^>]*>[^<]*<\/span>/g, "").replace(/<[^>]*>/g, " "), /\b(SOC 2|ISO 27001|GDPR|PCI DSS|NIST CSF)\b/,
      "a framework name in this paragraph is not marked up");
  }
});
