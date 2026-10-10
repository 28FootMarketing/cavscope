// Compliance section of the Super Admin Console (admin.html).
//
//   node --experimental-strip-types --test tests/ui/console-compliance.test.ts
//
// The unassessed bucket counted NULL in a column that cannot be null, the rate scored an
// unassessed control as a failure, and "derived from scanner evidence" included controls a person
// typed in. The bars would also have stopped adding up the day a not_assessed control existed.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const html = readFileSync(join(root, "admin.html"), "utf8");
const mig = readFileSync(join(root, "supabase/migrations/20261010192409_admin_console_compliance_wiring.sql"), "utf8");
const page = html.slice(html.indexOf("function renderCompliance()"), html.indexOf("function jurisdictionQueue()"));

test("not-assessed controls get a bar of their own, so the bars add up to the total", () => {
  assert.match(page, /bar\('Not assessed', c\.unassessed/);
  assert.match(page, /c\.not_applicable \? bar\('Not applicable'/);
});

test("the page states the rate's denominator and that hand-entered controls are excluded", () => {
  assert.match(page, /of \$\{num\(c\.assessed\)\} assessed/);
  assert.match(page, /entered by hand/);
});

test("a by-framework table renders from the payload and says a mapping is a citation", () => {
  assert.match(page, /frameworkBreakdown\(\)/);
  assert.match(html, /DATA\.compliance_by_framework/);
  assert.match(html, /A framework reference is a citation, not a test/);
});

test("the Overview tile uses the assessed count as its denominator", () => {
  assert.match(html, /met of \$\{num\(comp\.assessed\)\} assessed/);
});

test("migration: derived only, rate over assessed, unassessed matches the column's values", () => {
  assert.match(mig, /c\.assessment = ''not_assessed''/);
  assert.match(mig, /''unassessed'', count\(\*\) filter \(where c\.assessment = ''not_assessed''\)/);
  assert.match(mig, /where c\.source = ''derived''\)/);
  assert.match(mig, /compliance_by_framework/);
  assert.match(mig, /expected exactly 1 match/);
});
