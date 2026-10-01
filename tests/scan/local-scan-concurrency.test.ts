// The local-scan adapter writes the engine it builds to one shared file in the
// OS temp dir, and three test files (aio, legal, local-scan) call it from
// separate processes at the same moment.
//
//   node --experimental-strip-types --test tests/scan/local-scan-concurrency.test.ts
//
// loadEngine() used to writeFile() that path directly. writeFile truncates and
// then writes, so a second process that imported the file in between saw an
// empty or half-written module: no exports, and the failure
// "engine.runScan is not a function". It showed up in CI as two tests failing
// on one run and passing on the next run of the same commit (#182), which is
// exactly what a race looks like and is why "it passed the second time" is not
// an answer.
//
// This test is that situation on purpose: many processes build and import the
// engine at once, and every one of them must come back with a runScan.

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");

const CHILD = `
  import { loadEngine } from "./tools/local-scan/adapt.mjs";
  const mod = await import(await loadEngine());
  if (typeof mod.runScan !== "function") { console.error("runScan is " + typeof mod.runScan); process.exit(3); }
`;

function runChild(): Promise<{ code: number | null; stderr: string }> {
  return new Promise((resolve) => {
    const p = spawn(process.execPath, ["--experimental-strip-types", "--input-type=module", "-e", CHILD], { cwd: repoRoot });
    let stderr = "";
    p.stderr.on("data", (d) => (stderr += d));
    p.on("close", (code) => resolve({ code, stderr }));
  });
}

test("many processes building the local engine at once all get a runScan", async () => {
  const ROUNDS = 6;
  const PROCS = 10;
  const failures: string[] = [];
  for (let round = 0; round < ROUNDS; round++) {
    const results = await Promise.all(Array.from({ length: PROCS }, runChild));
    for (const r of results) if (r.code !== 0) failures.push(`exit ${r.code}: ${r.stderr.trim().split("\n").pop()}`);
  }
  assert.deepEqual(failures, [], `${failures.length} of ${ROUNDS * PROCS} processes could not load the engine`);
});
