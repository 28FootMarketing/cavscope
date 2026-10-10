// Reports section of the Super Admin Console (admin.html).
//
//   node --experimental-strip-types --test tests/ui/console-reports.test.ts
//
// The index asked for 200 of 266 reports under a heading that said "every", the markdown
// button claimed a hash "printed in the report" that only the PDFs print, and the page said a
// SITREP follows every completed scan when the browser-engine scan (250) has none.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const html = readFileSync(join(root, "admin.html"), "utf8");

test("the report index asks for the most the RPC allows and says when it is capped", () => {
  assert.match(html, /const SITREP_LIMIT = 500/);
  assert.match(html, /cavscope_admin_sitreps', \{ p_limit: SITREP_LIMIT \}/);
  assert.doesNotMatch(html, /p_limit: 200 \}/);
  assert.match(html, /older reports are not listed/);
});

test("the page does not claim a report follows every scan", () => {
  assert.doesNotMatch(html, /A SITREP is written after every completed scan/);
  assert.match(html, /browser-engine scan does not write one yet/);
});

test("the stored hash is shown, and the markdown tooltip says where it is printed", () => {
  assert.match(html, /r\.content_sha256 \?/);
  assert.match(html, /The markdown itself does not contain the hash/);
  assert.doesNotMatch(html, /matches the hash printed in the report, so/);
});
