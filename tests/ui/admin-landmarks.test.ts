// The Super Admin Console must have one h1, its content inside landmarks, and red scores readable.
// Found 2026-10-10 by rendering /admin signed in (tools/site-axe/admin.mjs): sections had no h1, the
// bottom strip sat outside every landmark, and `.score.red` was --rose text at 3.9:1.
//
//   node --experimental-strip-types --test tests/ui/admin-landmarks.test.ts

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const html = readFileSync(join(dirname(fileURLToPath(import.meta.url)), "..", "..", "admin.html"), "utf8");

test("one h1, in the shell, for every section", () => {
  assert.equal((html.match(/<h1[\s>]/g) ?? []).length, 2, "the shell's sr-only h1 and the print report's own h1 (a separate document)");
  assert.match(html, /<header class="topbar">\s*<h1 class="sr-only">Super Admin Console<\/h1>/);
});

test("the bottom strip is a footer landmark", () => {
  assert.match(html, /<footer class="strip">[\s\S]*?<\/footer>/);
  assert.doesNotMatch(html, /<div class="strip">/);
});

test("red scores use the readable red", () => {
  assert.match(html, /\.score\.red \{[^}]*color: var\(--rose-text\)/);
});
