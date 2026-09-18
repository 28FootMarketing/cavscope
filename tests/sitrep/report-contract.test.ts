// The SITREP must not state a count it does not render.
//
//   node --experimental-strip-types --test tests/sitrep/report-contract.test.ts
//
// muster.generate_sitrep carried `limit 12` on its finding loop from the first
// migration. SITREP 55 (Hanover Area YMCA) therefore said "14 open findings: 0
// critical, 1 high, 3 medium, 7 low, 3 informational" and rendered 12, showing one
// informational. GOV-003 and GOV-004 were absent and nothing said so.
//
// Nothing could have caught that, because the count and the list were computed from
// different queries and never compared. The migration that fixed it asserts them
// equal against live data; this test guards the source, so a future edit cannot
// reintroduce a bare numeric cap without the assertion that goes with it.
//
// The subject is the newest migration that redefines the generator, found by
// scanning rather than by a hardcoded filename -- the next person to change this
// function will add a file, not edit one, because migrations are append-only.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const migrationsDir = join(repoRoot, "supabase", "migrations");

const generatorMigrations = readdirSync(migrationsDir)
  .filter((f) => f.endsWith(".sql"))
  .filter((f) =>
    /create or replace function muster\.generate_sitrep/i.test(
      readFileSync(join(migrationsDir, f), "utf8"),
    ),
  )
  .sort();

const newest = generatorMigrations[generatorMigrations.length - 1];
const sql = readFileSync(join(migrationsDir, newest), "utf8");

test("a migration defining the generator exists and is discoverable", () => {
  assert.ok(generatorMigrations.length > 0, "no migration defines muster.generate_sitrep");
  // Version-ordered filenames are what makes "newest" meaningful here.
  assert.match(newest, /^\d{14}_muster_\d+_/);
});

test("the finding loop has no bare numeric cap", () => {
  // `limit 12` is the exact defect. A named constant is fine -- it can be reasoned
  // about, and the report discloses it when it binds -- but a literal in the loop is
  // how findings went missing for the life of the product.
  const loop = sql.slice(sql.indexOf("from muster.findings fi join muster.scan_rules"));
  const cap = loop.slice(0, loop.indexOf("loop"));
  assert.doesNotMatch(cap, /limit\s+\d+/i, "the finding loop caps on a literal");
  assert.match(cap, /limit\s+c_max_findings/i);
});

test("the cap is disclosed when it binds", () => {
  // Trimming is allowed. Trimming silently is not.
  assert.match(sql, /if v_open > v_shown then/);
  assert.match(sql, /This report details the %s most severe of %s open findings/);
});

test("the report states how many of how many it is showing", () => {
  assert.match(sql, /Showing %s of %s open finding/);
});

test("the header is a markdown table", () => {
  // Three lines joined by single newlines are ONE paragraph in CommonMark. The bug
  // was invisible in the product -- admin.html uses <pre>, sitrep.html never reads
  // content_md -- and only appeared once the file was forwarded, which is its job.
  assert.match(sql, /\| Organization \| %s \|/);
  assert.match(sql, /\| Target \| %s \|/);
  assert.doesNotMatch(sql, /Organization: %s\\nTarget:/);
});

test("the markdown renders the findings section, so it agrees with the viewer", () => {
  // sitrep.html renders top_findings; the markdown did not, so the console reader
  // saw strictly less than the tenant -- the opposite of what CLAUDE.md claims the
  // verbatim <pre> rendering buys.
  assert.match(sql, /## Findings/);
  assert.match(sql, /jsonb_array_elements\(v_top\)/);
});

test("the report states its own scope", () => {
  const required = [
    /does not execute JavaScript/,
    /does not crawl the whole site/,
    /never signs in/,
    /citations, not test results/,
    /not a statement that the site is secure/,
  ];
  assert.match(sql, /## What This Scan Did Not Check/);
  for (const r of required) assert.match(sql, r, String(r));
  // Never describe MUSTER as providing a SOC 2 opinion.
  assert.match(sql, /not a SOC 2 opinion/);
});

test("a scan that read nothing says so, and does not report a status it never got", () => {
  assert.doesNotMatch(sql, /'no response'/);
  assert.match(sql, /No readable HTTP response was returned by/);
  assert.match(sql, /AVAIL-001','AVAIL-003','AVAIL-004/);
});

test("citations cover the findings section, not just the board claims", () => {
  // The per-finding claims moved out of board_report. Without this the report would
  // cite less than it shows, which is the same defect in a different column.
  assert.match(sql, /jsonb_array_elements\(v_top\) x;/);
  assert.match(sql, /'claim_id', 'T'\|\|\(x->>'rank'\)/);
});

test("the citation trim is ordered before it is cut", () => {
  // An unordered `limit 5` cited F305, F307, F308, F309, F310 and skipped F306,
  // which reads as a lost finding rather than as a trim.
  assert.match(sql, /order by y::bigint limit 5/);
});
