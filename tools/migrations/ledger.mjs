// Compare supabase/migrations/ against what Postgres actually recorded.
//
// The one invariant this directory rests on is that a file here IS the statement
// that ran, byte for byte. Nothing enforced it, and on 2026-09-16 three files had
// drifted from it: two by two bytes (one of which is written into
// feature_flags.description, so the file described live data inaccurately) and one
// by eleven appended comment lines. All three were found by hand, which is not a
// process.
//
// Split in two on purpose, the same way muster-auth-smoke is:
//
//   - The checks that need no database (filename shape, duplicate versions,
//     duplicate or out-of-order sequence numbers) run in CI on every push, via
//     tests/migrations/ledger.test.ts. The muster_052 collision would have failed
//     there the moment it existed.
//   - The comparison against the ledger needs credentials CI does not have, so it
//     is a tool a human or an agent runs: tools/migrations/check.mjs.
//
// Everything here is pure so both callers can share it and the tests can feed it
// the exact defects that were found, rather than a plausible imitation.

import { createHash } from "node:crypto";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

/** The SQL that produces the ledger dump check.mjs reads. */
export const LEDGER_SQL = `select version, name,
       md5(array_to_string(statements,'')) as md5_raw,
       md5(array_to_string(statements,'') || E'\\n') as md5_nl,
       array_to_string(statements,'') as statement
from supabase_migrations.schema_migrations
order by version;`;

// <version>_<name>.sql, where <version> is what apply_migration assigned from its
// own clock. A three-digit muster_NNN inside <name> is a reading aid and is
// optional -- README.md is explicit that nothing keys on it -- so a file without
// one is not a defect, but two files sharing one is.
const FILENAME = /^(\d{14})_(.+)\.sql$/;
const SEQ = /^muster_(\d{3})_/;

export function parseMigrationFilename(file) {
  const m = FILENAME.exec(file);
  if (!m) return null;
  const seq = SEQ.exec(m[2]);
  return { file, version: m[1], name: m[2], seq: seq ? Number(seq[1]) : null };
}

export function readMigrationDir(dir) {
  return readdirSync(dir)
    .filter((f) => f.endsWith(".sql"))
    .sort()
    .map((f) => {
      const parsed = parseMigrationFilename(f);
      if (!parsed) return { file: f, version: null, name: null, seq: null, md5: null };
      const bytes = readFileSync(join(dir, f));
      return { ...parsed, md5: createHash("md5").update(bytes).digest("hex") };
    });
}

/**
 * Problems visible without a database. This is what CI can run.
 *
 * Gaps in the sequence are NOT reported. A gap means a migration was applied from
 * a branch that has not merged yet, which is ordinary and self-correcting; making
 * it an error would turn every in-flight branch red.
 */
export function localProblems(files) {
  const problems = [];
  const byVersion = new Map();
  const bySeq = new Map();

  for (const f of files) {
    if (!f.version) {
      problems.push({ kind: "bad_filename", file: f.file,
        detail: "not <14-digit version>_<name>.sql -- the version is what apply_migration assigned, read back from the ledger" });
      continue;
    }
    if (!byVersion.has(f.version)) byVersion.set(f.version, []);
    byVersion.get(f.version).push(f);
    if (f.seq !== null) {
      if (!bySeq.has(f.seq)) bySeq.set(f.seq, []);
      bySeq.get(f.seq).push(f);
    }
  }

  for (const [version, group] of byVersion) {
    if (group.length > 1) {
      problems.push({ kind: "duplicate_version", version,
        detail: `${group.length} files claim version ${version}: ${group.map((g) => g.file).join(", ")}` });
    }
  }

  for (const [seq, group] of bySeq) {
    if (group.length > 1) {
      problems.push({ kind: "duplicate_sequence", seq,
        detail: `muster_${String(seq).padStart(3, "0")} is claimed by ${group.length} files: ${group.map((g) => g.file).join(", ")}` });
    }
  }

  // Sequence numbers must rise with the version, or they mislead about order --
  // which is the whole and only reason they exist.
  const numbered = files.filter((f) => f.version && f.seq !== null)
    .sort((a, b) => a.version.localeCompare(b.version));
  for (let i = 1; i < numbered.length; i++) {
    if (numbered[i].seq < numbered[i - 1].seq) {
      problems.push({ kind: "sequence_out_of_order", file: numbered[i].file,
        detail: `${numbered[i].file} is later by version than ${numbered[i - 1].file} but carries a lower sequence number` });
    }
  }

  return problems;
}

/**
 * Compare the directory to the ledger.
 *
 * A file matches when its bytes hash to the recorded statement, or to that
 * statement plus one trailing newline -- the documented difference for files that
 * end in a newline and statements that did not. Nothing else counts as a match.
 */
export function compareToLedger(files, rows) {
  const byVersion = new Map(files.filter((f) => f.version).map((f) => [f.version, f]));
  const seen = new Set();
  const matched = [], diverged = [], appliedWithoutFile = [];

  for (const row of rows) {
    const file = byVersion.get(row.version);
    if (!file) { appliedWithoutFile.push(row); continue; }
    seen.add(row.version);
    if (file.md5 === row.md5_raw || file.md5 === row.md5_nl) matched.push({ file, row });
    else diverged.push({ file, row });
  }

  // A file for a version the ledger has never seen. On the old shared project this
  // is what left sixteen of them -- SQL written, filename guessed from the day it
  // was written, never applied, and read later as history that had happened.
  const forwardReferences = files.filter((f) => f.version && !seen.has(f.version)
    && !rows.some((r) => r.version === f.version));

  return { matched, diverged, appliedWithoutFile, forwardReferences };
}

/** First differing line, for a divergence the dump carried statement text for. */
export function firstDifference(fileText, statement) {
  const a = fileText.split("\n"), b = statement.split("\n");
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    if (a[i] !== b[i]) {
      return { line: i + 1, file: a[i] ?? "(file ends)", ledger: b[i] ?? "(statement ends)" };
    }
  }
  return null;
}
