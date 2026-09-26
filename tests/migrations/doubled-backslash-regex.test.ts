// A plpgsql string literal is not an escape-processed string. With
// standard_conforming_strings on (the default, and what this project runs
// under), a backslash inside a plain '...' literal is just a literal
// backslash character -- so a regex meant to escape a metacharacter needs
// ONE backslash ('\.'), not two ('\\.' means "a literal backslash, then any
// character"). The same applies to a regexp_replace backreference: '\1' is
// the captured group, '\\1' is the two-character string "\1".
//
//   node --experimental-strip-types --test tests/migrations/doubled-backslash-regex.test.ts
//
// This exact mistake has landed in muster.do_add_website's URL validation
// TWICE: muster_015 (2026-09-07), fixed same-day by muster_016, and then
// muster_112 (2026-09-26) re-introduced it by copying the function body out
// of muster_015's own (still-broken) file text rather than the live,
// muster_016-corrected definition, and CREATE OR REPLACE'd over the fix.
// Caught by hand against the live project before merging (empirically:
// 'https://example.com' failed the doubled-backslash pattern), and fixed
// again by muster_113. Both times the doubled form made every real URL
// rejected -- do_add_website is the only path either onboarding or the
// manual "add website" RPC use to create a website row, so this is not a
// cosmetic bug, it is "nobody can add a website" for as long as it ships.
//
// Guards the newest definition, found by scanning rather than a hardcoded
// filename -- the next person to touch this function adds a migration, they
// do not edit one.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const migrationsDir = join(repoRoot, "supabase", "migrations");

const defsFor = (fnName: string) =>
  readdirSync(migrationsDir)
    .filter((f) => f.endsWith(".sql"))
    .filter((f) => new RegExp(`create or replace function ${fnName.replace(".", "\\.")}`, "i").test(
      readFileSync(join(migrationsDir, f), "utf8"),
    ))
    .sort();

function newestBody(fnName: string): string {
  const files = defsFor(fnName);
  assert.ok(files.length > 0, `no migration defines ${fnName}`);
  const sql = readFileSync(join(migrationsDir, files[files.length - 1]), "utf8");
  const start = sql.search(new RegExp(`create or replace function ${fnName.replace(".", "\\.")}`, "i"));
  const end = sql.indexOf("$function$\n;", start);
  assert.ok(start >= 0 && end > start, `could not isolate ${fnName}'s body in ${files[files.length - 1]}`);
  return sql.slice(start, end);
}

// Plain substring checks, deliberately, rather than a regex matching a
// regex: this file's entire subject is how easy it is to miscount
// backslashes across an escaping boundary, so it does not lean on JS regex
// escaping to verify Postgres regex escaping. Each needle below is written
// out with an explicit backslash count in a comment, checked by hand against
// `body` printed via console.log while authoring this test.

test("the current do_add_website URL regex uses a single backslash before the dot", () => {
  const body = newestBody("muster.do_add_website");
  // correct: ...]+ \ . [a-z]{2,}...  (ONE backslash before the dot)
  assert.ok(body.includes("[a-z0-9.-]+\\.[a-z]{2,}"), "expected a single backslash escaping the dot");
  // broken: ...]+ \ \ . [a-z]{2,}...  (TWO backslashes -- requires a literal
  // backslash character in every URL, so it rejects all of them)
  assert.ok(!body.includes("[a-z0-9.-]+\\\\.[a-z]{2,}"), "a doubled backslash here requires a literal backslash in every URL, rejecting all of them");
});

test("the current do_add_website hostname fallback uses a single-backslash backreference", () => {
  const body = newestBody("muster.do_add_website");
  // correct: '...$', '\1')  (ONE backslash -- the regexp_replace backreference)
  assert.ok(body.includes("'^https?://([^/]+).*$', '\\1')"), "expected a single-backslash backreference (\\1)");
  // broken: '...$', '\\1')  (TWO backslashes -- regexp_replace reads this as
  // an escaped literal backslash followed by the character "1", so the
  // result is the literal string "\1", not the captured hostname)
  assert.ok(!body.includes("'^https?://([^/]+).*$', '\\\\1')"), "a doubled backslash here emits the literal string \\1 instead of the captured hostname");
});
