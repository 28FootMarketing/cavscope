// Instructions and long lists open one at a time.
//
//   node --experimental-strip-types --test tests/ui/accordions.test.ts
//
// Standing rule from 2026-09-30 (CLAUDE.md, "Instructions and long lists
// collapse"): a report's sections and each finding's fix are collapsible, and
// opening one closes the others in its group, so nobody scrolls past one item
// to reach the next. Printing opens everything, so a printed report or PDF is
// never missing a collapsed section. Checked in Chromium on 2026-09-30; this
// file pins the shape so a later edit cannot quietly drop it.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const read = (f: string) => readFileSync(join(root, f), "utf8");
const PAGES = ["app.html", "admin.html", "sitrep.html", "sitrep-sample.html"];

test("every page with collapsible content carries the engine and starts it", () => {
  for (const f of PAGES) {
    const src = read(f);
    assert.match(src, /function initAccordions\(\) \{/, `${f} has no accordion engine`);
    assert.match(src, /initTooltips\(\);\s*initAccordions\(\);/, `${f} never starts it`);
    assert.match(src, /details\.acc > summary \{ cursor: pointer;/, `${f} has no accordion styles`);
  }
});

test("opening one closes the rest of its group, and printing opens them all", () => {
  for (const f of PAGES) {
    const src = read(f);
    assert.match(src, /if \(o !== d && o\.dataset\.accGroup === group\) o\.open = false;/, f);
    assert.match(src, /window\.addEventListener\('beforeprint'/, f);
    assert.match(src, /window\.addEventListener\('afterprint'/, f);
  }
});

test("each report's sections collapse, first one open, with open-all and close-all", () => {
  assert.match(read("sitrep.html"), /accordionSections\(root, ':scope > section\.block', 'sitrep-sections'\);/);
  assert.match(read("sitrep-sample.html"), /accordionSections\(root, ':scope > section\.block', 'sample-sections'\);/);
  assert.match(read("app.html"), /accordionSections\(el, 'section\.rd-block', 'report-' \+ profile\);/);
  const app = read("app.html");
  assert.match(app, /if \(i === 0\) d\.open = true;/);
  assert.match(app, />Open all<\/button>/);
  assert.match(app, />Close all<\/button>/);
});

test("every finding's fix is a collapsible 'How to fix', one open at a time", () => {
  const groups: Array<[string, string]> = [
    ["sitrep.html", "sitrep-fix"], ["sitrep-sample.html", "sample-fix"],
    ["app.html", "report-fix"], ["app.html", "aio-fix"], ["app.html", "a11y-fix"],
  ];
  for (const [f, g] of groups) {
    assert.match(read(f), new RegExp(`<details class="acc acc-fix" data-acc-group="${g}"><summary>How to fix</summary>`), `${f} ${g}`);
  }
  // The remediation text is never dropped straight into a table cell any more.
  assert.doesNotMatch(read("sitrep.html"), /<td style="color:var\(--text-muted\);">\$\{escapeHtml\(f\.remediation \|\| ''\)\}<\/td>/);
});

test("the admin console's flag rows open one at a time too", () => {
  assert.match(read("admin.html"), /<details data-acc-group="flags" data-flag="\$\{key\}"/);
});
