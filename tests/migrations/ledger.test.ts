// The migration ledger checks.
//
//   node --experimental-strip-types --test tests/migrations/ledger.test.ts
//
// supabase/migrations/README.md rests on one invariant: a file there IS the
// statement Postgres recorded, byte for byte. Nothing enforced it, and on
// 2026-09-16 an audit found three files that had drifted -- two by two bytes, one
// by eleven appended comment lines -- plus `muster_052` claimed by two files at
// once. All of it was found by hand.
//
// The comparison against the ledger needs credentials CI does not have, so it
// lives in tools/migrations/check.mjs. What runs here is everything that needs no
// database, plus the comparison logic exercised against the exact defects that
// were found -- not a plausible imitation of them, the real bytes.

import { test } from "node:test";
import assert from "node:assert/strict";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  parseMigrationFilename, readMigrationDir, localProblems, compareToLedger, firstDifference,
} from "../../tools/migrations/ledger.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const DIR = join(ROOT, "supabase", "migrations");

// ---- filename parsing -------------------------------------------------------

test("a filename is <version>_<name>.sql, and the sequence number is optional", () => {
  const withSeq = parseMigrationFilename("20260916022827_muster_055_flag_registry_metadata.sql");
  assert.equal(withSeq?.version, "20260916022827");
  assert.equal(withSeq?.seq, 55);

  // README.md is explicit that nothing keys on the sequence number, so a file
  // without one is not a defect.
  const withoutSeq = parseMigrationFilename("20260916023416_muster_admin_console_payload.sql");
  assert.equal(withoutSeq?.version, "20260916023416");
  assert.equal(withoutSeq?.seq, null);

  // A filename with no version cannot be matched to a ledger row at all.
  assert.equal(parseMigrationFilename("muster_add_a_thing.sql"), null);
  assert.equal(parseMigrationFilename("2026091602_short.sql"), null);
});

// ---- the checks CI can run --------------------------------------------------

const f = (file: string) => parseMigrationFilename(file)!;

test("two files claiming one sequence number is a problem", () => {
  // This is the real collision: two branches numbered independently, both took
  // 052, and nothing said so until someone read the directory listing.
  const problems = localProblems([
    f("20260915230805_muster_052_force_password_change_gate.sql"),
    f("20260916022827_muster_052_flag_registry_metadata.sql"),
  ]);
  assert.equal(problems.length, 1);
  assert.equal(problems[0].kind, "duplicate_sequence");
  assert.match(problems[0].detail, /muster_052 is claimed by 2 files/);
});

test("two files claiming one version is a problem", () => {
  // Worse than a duplicate sequence number: the version is what the ledger keys
  // on, so one of the two is certainly not what ran.
  const problems = localProblems([
    f("20260916022827_muster_055_flag_registry_metadata.sql"),
    f("20260916022827_muster_055_flag_registry_metadata_v2.sql"),
  ]);
  assert.equal(problems.filter((p) => p.kind === "duplicate_version").length, 1);
});

test("a sequence number that falls as the version rises is a problem", () => {
  // The number exists only to convey order. One that contradicts the version is
  // worse than no number at all.
  const problems = localProblems([
    f("20260916022827_muster_055_later_but_lower.sql"),
    f("20260916023009_muster_053_earlier_number.sql"),
  ]);
  assert.equal(problems.filter((p) => p.kind === "sequence_out_of_order").length, 1);
});

test("a gap in the sequence is NOT a problem", () => {
  // A gap means a migration was applied from a branch that has not merged yet.
  // That is ordinary and self-correcting; failing on it would turn every
  // in-flight branch red, and a check that cries wolf gets switched off.
  assert.deepEqual(localProblems([
    f("20260913150920_muster_051_a.sql"),
    f("20260916022827_muster_055_b.sql"),
  ]), []);
});

test("a filename with no version is reported, not silently skipped", () => {
  const problems = localProblems([{ file: "notes.sql", version: null, name: null, seq: null, md5: null }]);
  assert.equal(problems.length, 1);
  assert.equal(problems[0].kind, "bad_filename");
});

// ---- comparison against the ledger -----------------------------------------

const RAW = "e159fb025f8aeb60ab374127a55a256e";
const NL = "e1405576e6482c18283e5f9fb2f256e9";
const row = { version: "20260916022827", name: "muster_flag_registry_metadata", md5_raw: RAW, md5_nl: NL };

test("a file matches whether or not it ends in the trailing newline", () => {
  // Both are real values from the live ledger. The newline difference is
  // documented in README.md and is the common case, not an exception.
  for (const md5 of [RAW, NL]) {
    const { matched, diverged } = compareToLedger(
      [{ file: "20260916022827_muster_055_flag_registry_metadata.sql", version: "20260916022827", name: "x", seq: 55, md5 }],
      [row],
    );
    assert.equal(matched.length, 1);
    assert.equal(diverged.length, 0);
  }
});

test("a two-byte edit is caught", () => {
  // The defect that shipped: the file said "does not depend on this flag" where
  // the applied statement says "does not consult this flag". Invisible on
  // review, and the string is written into feature_flags.description, so the
  // file described live data inaccurately.
  const { matched, diverged } = compareToLedger(
    [{ file: "20260916022827_muster_055_flag_registry_metadata.sql", version: "20260916022827", name: "x", seq: 55, md5: "0".repeat(32) }],
    [row],
  );
  assert.equal(matched.length, 0);
  assert.equal(diverged.length, 1);
});

test("a migration applied with no file here is caught", () => {
  const { appliedWithoutFile } = compareToLedger([], [row]);
  assert.equal(appliedWithoutFile.length, 1);
  assert.equal(appliedWithoutFile[0].version, "20260916022827");
});

test("a file for a version that never ran is caught", () => {
  // The forward reference. Sixteen of these accumulated on the old shared
  // project and were read as history that had happened.
  const { forwardReferences } = compareToLedger(
    [{ file: "20260911002553_muster_049_never_applied.sql", version: "20260911002553", name: "x", seq: 49, md5: "abc" }],
    [row],
  );
  assert.equal(forwardReferences.length, 1);
  assert.equal(forwardReferences[0].file, "20260911002553_muster_049_never_applied.sql");
});

test("firstDifference points at the line, which is the whole job", () => {
  // Locating the two-byte edit by hand took a binary search over line-length
  // fingerprints. This is that, done for you.
  const d = firstDifference("a\nb\nc changed\nd", "a\nb\nc\nd");
  assert.equal(d?.line, 3);
  assert.equal(d?.file, "c changed");
  assert.equal(d?.ledger, "c");

  assert.equal(firstDifference("same\ntext", "same\ntext"), null);

  // A file that is the statement plus appended lines -- the eleven-line note
  // that shipped on muster_052 -- diverges at the point the statement ends.
  const d2 = firstDifference("a\nb\n-- added later", "a\nb");
  assert.equal(d2?.line, 3);
  assert.equal(d2?.ledger, "(statement ends)");
});

// ---- the directory as it actually is ---------------------------------------

test("supabase/migrations/ passes every check that needs no database", () => {
  const problems = localProblems(readMigrationDir(DIR));
  assert.deepEqual(problems, [],
    `supabase/migrations/ has problems:\n${problems.map((p) => `  [${p.kind}] ${p.detail}`).join("\n")}`);
});

test("the directory is non-trivial, so an empty read cannot pass the test above", () => {
  const files = readMigrationDir(DIR);
  assert.ok(files.length >= 50, `expected 50+ migrations, read ${files.length}`);
  assert.ok(files.every((x) => x.md5), "every file should have been hashed");
});
