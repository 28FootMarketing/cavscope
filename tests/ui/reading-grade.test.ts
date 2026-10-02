// Tooltip copy is held to a reading-grade ceiling per page, so it cannot quietly get harder.
//
//   node --experimental-strip-types --test tests/ui/reading-grade.test.ts
//
// A ratchet, not a target. Ceilings are the measured grade on 2026-10-02 rounded up half a
// grade; lowering one after rewriting copy is the intended direction, raising one needs a
// reason in the commit. Flesch-Kincaid by vowel-group syllables is a rough instrument (about
// half a grade), so this catches drift, it does not certify readability.
// Scope: data-tooltip text only. Legal pages (privacy.html) are excluded on purpose: precise
// wording there outranks reading level. Source of the grader: tools/readability/grade.mjs.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { grade, gradeAll, countSyllables } from "../../tools/readability/grade.mjs";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");

const CEILINGS: Record<string, number> = {
  "index.html": 9.0,
  "app.html": 6.5,
  "admin.html": 6.5,
  "signin.html": 5.5,
  "onboarding.html": 6.5,
  "sitrep.html": 6.5,
  "sitrep-sample.html": 8.0,
};

const decode = (s: string) =>
  s.replace(/&amp;/g, "&").replace(/&quot;/g, '"').replace(/&#39;|&apos;/g, "'").replace(/&lt;/g, "<").replace(/&gt;/g, ">");

const tooltips = (page: string) =>
  [...readFileSync(join(repoRoot, page), "utf8").matchAll(/data-tooltip="([^"]+)"/g)]
    .map((m) => decode(m[1]))
    .filter((t) => !t.includes("${")); // template-built text is not readable as copy

test("grader sanity: plain copy scores low, dense copy scores high", () => {
  assert.ok(grade("The cat sat on the mat. It was a good day.") < 3);
  assert.ok(grade("Operationalizing comprehensive interoperability necessitates organizational accountability.") > 16);
  assert.equal(countSyllables("security"), 4);
  assert.equal(countSyllables("the"), 1);
});

for (const [page, ceiling] of Object.entries(CEILINGS)) {
  test(`${page}: tooltip copy stays at or under grade ${ceiling}`, () => {
    const t = tooltips(page);
    assert.ok(t.length > 0, `${page} has no tooltips to grade`);
    const g = gradeAll(t);
    assert.ok(
      g <= ceiling,
      `${page} tooltips grade ${g.toFixed(1)}, ceiling ${ceiling}. Hardest: ` +
        t.map((x) => [grade(x), x] as const).sort((a, b) => b[0] - a[0]).slice(0, 3)
          .map(([n, x]) => `[${n.toFixed(0)}] ${x}`).join(" | "),
    );
  });
}
