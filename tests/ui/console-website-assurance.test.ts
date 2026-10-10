// Website Assurance section of the Super Admin Console (admin.html).
//
//   node --experimental-strip-types --test tests/ui/console-website-assurance.test.ts
//
// posture_score() is 100 for a site with no open findings, including one nobody has scanned, so
// the console showed an unscanned site as a green 100 and banded an organization by it. That is
// absence of findings read as a pass.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const html = readFileSync(join(root, "admin.html"), "utf8");
const mig = readFileSync(join(root, "supabase/migrations/20261010191847_admin_console_unscanned_sites_are_not_scored.sql"), "utf8");
const sites = html.slice(html.indexOf("function renderWebsiteAssurance()"), html.indexOf("// ---- site location"));

test("an unscanned site is shown as not scanned, never as a score", () => {
  assert.match(sites, /w\.score == null \?/);
  assert.match(sites, /not scanned/);
  assert.doesNotMatch(sites, /<span class="score \$\{band\(w\.score\)\}">\$\{w\.score\}<\/span><\/td>\s*<td class="num/);
});

test("sandbox sites are marked", () => {
  assert.match(sites, /w\.sandbox \?/);
});

test("migration: score only where a scan completed, in the roster, the org worst score, org health and recent scans", () => {
  assert.match(mig, /sc\.status = ''complete''/);
  assert.equal((mig.match(/pg_temp\.sub\(d,/g) || []).length, 5);
  assert.match(mig, /filter \(where/);
  assert.match(mig, /expected exactly 1 match/);
});
