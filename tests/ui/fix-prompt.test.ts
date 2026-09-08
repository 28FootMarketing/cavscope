// The "Copy LLM Fix" buttons, tested by building the prompts they produce.
//
//   node --experimental-strip-types --test tests/ui/fix-prompt.test.ts
//
// buildFixPrompt is extracted from app.html rather than copied, so editing the
// prompt runs these assertions against the edit.
//
// What these guard is the defect that prompted them: the button used to emit
//   "Act as a senior engineer. Remediate finding 'defect_F23' for our domain
//    berecruitabledaily.com. Follow MUSTER assurance standards..."
// which hands a model an id it has never seen and nothing to act on, while
// MUSTER already held the title, impact, root cause, recommended fix, page URL
// and evidence ids for that exact finding.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");

function loadBuildFixPrompt() {
  const html = readFileSync(join(repoRoot, "app.html"), "utf8");
  const start = html.indexOf("    function buildFixPrompt(ctx) {");
  const end = html.indexOf("    function copyCardLlmPrompt(key) {");
  assert.notEqual(start, -1, "buildFixPrompt not found in app.html");
  assert.ok(end > start, "extraction anchors are out of order");
  const src = html.slice(start, end);
  const fn = new Function("siteForPrompt", src + "; return buildFixPrompt;");
  return fn(() => "berecruitabledaily.com") as (ctx: Record<string, unknown>) => string;
}

// The live shape, from Live.tenantFromOrg -> base.accessibility.defects.
const DEFECT = {
  id: "F23",
  fields: [
    ["Title", "Images missing alternative text"],
    ["Standard", "WCAG 1.1.1"],
    ["Severity", "P1"],
    ["Affected component", "homepage"],
    ["Page", "https://berecruitabledaily.com/"],
    ["Impact on users", "People using screen readers cannot tell what these images show."],
    ["Root cause MUSTER observed", "4 img elements have no alt attribute."],
    ["MUSTER recommended fix", 'Add alt text describing each meaningful image. Use alt="" for decorative images.'],
    ["How MUSTER validates it", "HTTP engine · evidence E88201, E88202"],
    ["Current status", "Open"],
  ],
};

test("the prompt carries the finding, not just its id", () => {
  const p = loadBuildFixPrompt()(DEFECT);
  for (const needle of [
    "Images missing alternative text",
    "WCAG 1.1.1",
    "https://berecruitabledaily.com/",
    "People using screen readers",
    "4 img elements have no alt attribute",
    "Add alt text describing each meaningful image",
    "E88201",
  ]) {
    assert.ok(p.includes(needle), `prompt is missing "${needle}" — it is back to naming an id only`);
  }
});

test("the old content-free phrasing is gone", () => {
  const p = loadBuildFixPrompt()(DEFECT);
  assert.ok(!/Follow MUSTER assurance standards and output production-ready code/.test(p),
    "the placeholder instruction survived");
  // Naming the id is fine; naming ONLY the id is the bug.
  assert.ok(p.length > 400, `prompt is too short to contain a finding: ${p.length} chars`);
});

test("the model is told what it was not given, so it asks instead of inventing", () => {
  const p = loadBuildFixPrompt()(DEFECT);
  assert.ok(/HAVE NOT BEEN GIVEN/.test(p), "no statement of what is missing");
  assert.ok(/source code/i.test(p), "does not say the source was not provided");
  assert.ok(/say what you need/i.test(p), "does not tell the model to ask");
  assert.ok(/[Dd]o not introduce findings/.test(p), "does not forbid inventing findings");
});

test("empty and missing fields are dropped rather than rendered blank", () => {
  const p = loadBuildFixPrompt()({
    id: "F99",
    fields: [["Title", "Something real"], ["Page", ""], ["Impact on users", null], ["Root cause MUSTER observed", undefined], ["Severity", "   "]],
  });
  assert.ok(p.includes("Title: Something real"));
  for (const label of ["Page:", "Impact on users:", "Root cause MUSTER observed:", "Severity:"]) {
    assert.ok(!p.includes(label), `empty field "${label}" was rendered anyway`);
  }
});

test("a finding with almost nothing still produces an honest prompt", () => {
  // The degenerate case must not read as though detail exists.
  const p = loadBuildFixPrompt()({ id: "F1", fields: [["Title", "Unknown"]] });
  assert.ok(p.includes("FINDING F1"));
  assert.ok(/say what you need/i.test(p), "a thin finding must still push the model to ask");
});

test("every registered field label reaches the prompt body", () => {
  const p = loadBuildFixPrompt()(DEFECT);
  for (const [label] of DEFECT.fields) {
    assert.ok(p.includes(`- ${label}:`), `label "${label}" was dropped`);
  }
});
