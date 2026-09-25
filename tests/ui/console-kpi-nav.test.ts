// The six KPI tiles on the Super Admin Console overview open the section
// each one summarises.
//
//   node --experimental-strip-types --test tests/ui/console-kpi-nav.test.ts
//
// Until 2026-09-25 the tiles were static cards: a tooltip and a number, no
// door. The workspace's Posture Overview cards had already been made to
// navigate (app.html, navigateCard), and the owner clicked a console tile
// expecting the same and got nothing. What is pinned here is not that a click
// navigates -- the delegated [data-section] handler already does that for the
// sidebar -- but the three ways this can quietly regress: a tile pointing at a
// section id that does not exist, a tile pointing at one of the "not
// instrumented" stubs, and the keyboard path being dropped so a div that
// says role=button stops being one.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const html = readFileSync(join(repoRoot, "admin.html"), "utf8");

/** SECTIONS as the page declares them: id -> stub? */
function sections(): Map<string, boolean> {
  const block = html.slice(html.indexOf("const SECTIONS = ["), html.indexOf("];", html.indexOf("const SECTIONS = [")));
  const out = new Map<string, boolean>();
  for (const m of block.matchAll(/\{ id: '([a-z-]+)'[^}]*?(stub: true)?\s*\}/g)) out.set(m[1], !!m[2]);
  assert.ok(out.size >= 10, "SECTIONS did not parse");
  return out;
}

/** Every tile's `go` target, in declaration order. */
function tileTargets(): Array<[string, string]> {
  const block = html.slice(html.indexOf("const tiles = ["), html.indexOf("];", html.indexOf("const tiles = [")));
  const out: Array<[string, string]> = [];
  for (const m of block.matchAll(/label: '([^']+)', go: '([a-z-]+)'/g)) out.push([m[1], m[2]]);
  return out;
}

test("every KPI tile names a section", () => {
  const targets = tileTargets();
  assert.equal(targets.length, 6, "six tiles, six targets");
  assert.deepEqual(targets.map(([label]) => label), [
    "Active Organizations", "Assessments Running", "High-Risk Alerts",
    "Control Effectiveness", "Monthly Revenue", "API Usage",
  ]);
});

test("every target is a real section, and none is a stub", () => {
  const known = sections();
  for (const [label, go] of tileTargets()) {
    assert.ok(known.has(go), `${label} points at '${go}', which is not in SECTIONS`);
    assert.equal(known.get(go), false, `${label} points at '${go}', a not-instrumented stub -- a door onto an empty room`);
  }
});

test("the tile is rendered as a keyboard-reachable button that the delegated handler routes", () => {
  assert.match(html, /<div class="card kpi" role="button" tabindex="0" data-section="\$\{t\.go\}"/);
  // Enter and Space activate it, and Space does not also scroll the page.
  assert.match(html, /closest\('\[role="button"\]\[data-section\]'\)/);
  assert.match(html, /e\.key === 'Enter' \|\| e\.key === ' '/);
});

test("the tooltip and the screen-reader text both say where the tile goes", () => {
  // Tooltip rule: what it does, from the reader's side.
  assert.match(html, /Click to open \$\{escapeHtml\(sectionLabel\(t\.go\)\)\}\./);
  // Not an aria-label on the tile: that would replace the live figure for a
  // screen reader instead of adding to it.
  assert.doesNotMatch(html, /class="card kpi"[^>]*aria-label=/);
  assert.match(html, /<span class="sr-only"> Opens \$\{escapeHtml\(sectionLabel\(t\.go\)\)\}\.<\/span>/);
});
