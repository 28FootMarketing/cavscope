// Companion to tests/email/alert-dispatch-cta.test.ts: that file pins the
// HTML button's destination (CATEGORY_META.ctaHref in
// muster-alert-dispatch/index.ts); this pins the plain-text part sent
// alongside it, which carries its own literal copy of the same URL inside
// cavscope.autotriage()'s risk_opened body_text ("View full detail: ...").
// A text-only mail client never sees the HTML button, so fixing one without
// the other would have left half of every risk_opened send pointing at the
// generic workspace root.
//
//   node --experimental-strip-types --test tests/migrations/cta-deep-link.test.ts
//
// Matches both the muster.autotriage(...) and cavscope.autotriage() forms
// the function has been defined under across migration history (the schema
// was renamed muster -> cavscope in migration muster_110, out of sequence
// order -- see that file's header) and picks the file that is actually
// newest by filename, which sorts correctly either way since every
// migration filename is timestamp-prefixed.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const migrationsDir = join(repoRoot, "supabase", "migrations");

function newestAutotriageBody(): string {
  const files = readdirSync(migrationsDir)
    .filter((f) => f.endsWith(".sql"))
    .filter((f) => /create or replace function (muster|cavscope)\.autotriage\(/i.test(
      readFileSync(join(migrationsDir, f), "utf8"),
    ))
    .sort();
  assert.ok(files.length > 0, "no migration defines autotriage()");
  const sql = readFileSync(join(migrationsDir, files[files.length - 1]), "utf8");
  const start = sql.search(/create or replace function (muster|cavscope)\.autotriage\(/i);
  const end = sql.indexOf("$function$\n;", start);
  assert.ok(start >= 0 && end > start, `could not isolate autotriage's body in ${files[files.length - 1]}`);
  return sql.slice(start, end);
}

test("risk_opened's plain-text CTA carries the same #risks destination as the HTML button", () => {
  const body = newestAutotriageBody();
  assert.match(body, /View full detail: https:\/\/app\.muster\.partners\/app#risks\\n/);
  assert.ok(
    !body.includes("View full detail: https://app.muster.partners/app\\n"),
    "the plain-text link regressed to the bare workspace root",
  );
});
