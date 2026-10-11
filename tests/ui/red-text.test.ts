// Red TEXT uses --rose-text, never --rose. --rose (#f43f5e) is 3.9:1 on the tinted pill and badge backgrounds
// these pages draw it on; --rose-text (#fb7185) passes. CLAUDE.md has said so since 2026-10-05, but the rule was
// only applied where the first browser scan happened to look: 17 more text colours, across the console's critical
// pill and action icons and the workspace's severity chips, were found 2026-10-11 by running tools/site-axe/admin.mjs
// with a support-access session open. Borders, backgrounds and chart fills may still use --rose.
//
//   node --experimental-strip-types --test tests/ui/red-text.test.ts

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const read = (p: string) => readFileSync(join(root, p), "utf8");

for (const page of ["app.html", "admin.html", "tools/support/widget.html"]) {
  test(`${page}: no text colour is var(--rose)`, () => {
    const offenders = read(page).split("\n").map((l, i) => [i + 1, l] as const)
      .filter(([, l]) => /(?<![-\w])color: var\(--rose\)(?=[;\s}])/.test(l));
    assert.deepEqual(offenders.map(([n, l]) => `${n}: ${l.trim().slice(0, 100)}`), []);
  });
}

test("the support-access banner's reason line is readable on its amber tint", () => {
  assert.match(read("admin.html"), /\.imp-why \{ color: var\(--text\);/);
});
