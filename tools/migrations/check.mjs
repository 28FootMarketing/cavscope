#!/usr/bin/env node
// Check supabase/migrations/ against the ledger of what actually ran.
//
//   node tools/migrations/check.mjs --sql                 print the dump query
//   node tools/migrations/check.mjs --ledger ledger.json  compare against a dump
//   node tools/migrations/check.mjs                       local checks only
//
// The dump is produced by whoever holds credentials -- the Supabase MCP, psql, or
// the dashboard SQL editor -- and saved as the JSON array that query returns.
// This tool never connects to anything itself: it takes no connection string, so
// it cannot leak one, and it can be run against a dump someone pasted into a file.
//
// Exit code is 1 if anything is wrong, so it can gate a release.

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  LEDGER_SQL, readMigrationDir, localProblems, compareToLedger, firstDifference,
} from "./ledger.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const DIR = join(ROOT, "supabase", "migrations");

const args = process.argv.slice(2);
if (args.includes("--sql")) {
  console.log(LEDGER_SQL);
  process.exit(0);
}

const ledgerFlag = args.indexOf("--ledger");
const ledgerPath = ledgerFlag === -1 ? null : args[ledgerFlag + 1];

const files = readMigrationDir(DIR);
let failed = false;

console.log(`supabase/migrations/: ${files.length} files\n`);

const problems = localProblems(files);
if (problems.length) {
  failed = true;
  console.log(`Local problems (${problems.length}) -- these need no database:\n`);
  for (const p of problems) console.log(`  [${p.kind}] ${p.detail}`);
  console.log("");
} else {
  console.log("Local checks pass: filenames well-formed, versions unique, sequence numbers unique and in order.\n");
}

if (!ledgerPath) {
  console.log("No --ledger given, so the directory was NOT compared to what actually ran.");
  console.log("Get the dump with:  node tools/migrations/check.mjs --sql");
  process.exit(failed ? 1 : 0);
}

let rows;
try {
  rows = JSON.parse(readFileSync(ledgerPath, "utf8"));
} catch (err) {
  console.error(`Could not read ${ledgerPath}: ${err.message}`);
  process.exit(1);
}
if (!Array.isArray(rows)) {
  console.error(`${ledgerPath} is not the JSON array the query returns.`);
  process.exit(1);
}

const { matched, diverged, appliedWithoutFile, forwardReferences } = compareToLedger(files, rows);

console.log(`Ledger: ${rows.length} applied migrations\n`);
console.log(`  ${matched.length} match the recorded statement`);
console.log(`  ${diverged.length} diverge`);
console.log(`  ${appliedWithoutFile.length} applied with no file here`);
console.log(`  ${forwardReferences.length} files for versions never applied\n`);

if (diverged.length) {
  failed = true;
  console.log("DIVERGED -- the file claims to be the applied statement and is not.");
  console.log("The database is right; the file is what needs changing.\n");
  for (const { file, row } of diverged) {
    console.log(`  ${file.file}`);
    if (row.statement) {
      const text = readFileSync(join(DIR, file.file), "utf8");
      const d = firstDifference(text.endsWith("\n") ? text.slice(0, -1) : text, row.statement);
      if (d) {
        console.log(`    first difference, line ${d.line}:`);
        console.log(`      file   | ${d.file}`);
        console.log(`      ledger | ${d.ledger}`);
      }
    } else {
      console.log(`    md5 ${file.md5} != ${row.md5_raw} (dump carried no statement text, so no diff)`);
    }
  }
  console.log("");
}

if (appliedWithoutFile.length) {
  failed = true;
  console.log("APPLIED WITH NO FILE -- ran against the database, not recorded here.");
  console.log("Usually means the branch that applied it has not merged yet; check before writing a new file,");
  console.log("because two files for one version is worse than none.\n");
  for (const r of appliedWithoutFile) console.log(`  ${r.version}  ${r.name}`);
  console.log("");
}

if (forwardReferences.length) {
  failed = true;
  console.log("FORWARD REFERENCES -- a file for a version the ledger has never seen.");
  console.log("This is the failure that left sixteen of them on the old shared project: SQL written,");
  console.log("filename guessed from the day it was written, never applied, read later as history.\n");
  for (const f of forwardReferences) console.log(`  ${f.file}`);
  console.log("");
}

console.log(failed ? "FAIL" : "OK -- every applied migration has a file here, and every file is what ran.");
process.exit(failed ? 1 : 0);
