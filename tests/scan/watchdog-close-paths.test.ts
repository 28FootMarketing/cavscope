// Every incident source the watchdog can open must also be one it can close.
//
//   node --experimental-strip-types --test tests/scan/watchdog-close-paths.test.ts
//
// CLAUDE.md states the rule: "A new check that reports an incident needs a matching
// close path, or it is a counter, not an alarm." Open-incident count is only a usable
// signal while it can go down. It was fixed once for engine_error_spike (2026-09-13)
// and once for control_register_failure, and nothing stopped the other five sources
// from having the same defect, so they did:
//
//   * cron_failure and cron_missed open at CRITICAL severity and could never close.
//     One failed cron run would have left a critical incident open permanently.
//   * scan_silent_failure left 39 incidents open from 2026-09-17 to 2026-09-28, each a
//     single past scan (fingerprinted by scan id), none of which any later run could
//     reach.
//   * commercial_grant_stuck and alert_dead_letter had the same shape.
//
// This test is the rule, written down: it reads the watchdog's source, collects every
// source it passes to reportIncident, and requires a closeCleared for the same one.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const src = readFileSync(join(repoRoot, "supabase", "functions", "cavscope-watchdog", "index.ts"), "utf8");

// reportIncident(<fingerprint>, "<source>", ...) where the fingerprint is a template
// literal or a string and may sit on its own line.
const opened = new Set([...src.matchAll(/reportIncident\(\s*(?:`[^`]*`|"[^"]*"),\s*"([a-z_]+)"/g)].map((m) => m[1]));
const closed = new Set([...src.matchAll(/closeCleared\(\s*"([a-z_]+)"/g)].map((m) => m[1]));

test("the watchdog opens the incident sources this test knows about", () => {
  // If this list is wrong the next test is checking nothing: a regex that stops
  // matching would pass vacuously on an empty set.
  assert.deepEqual(
    [...opened].sort(),
    ["alert_dead_letter", "commercial_grant_stuck", "control_register_failure", "cron_failure", "cron_missed", "engine_error_spike", "scan_silent_failure"],
  );
});

test("every incident source the watchdog opens is also closed when its condition clears", () => {
  const unclosable = [...opened].filter((s) => !closed.has(s)).sort();
  assert.deepEqual(unclosable, [], `these sources open incidents that nothing can ever close: ${unclosable.join(", ")}`);
});

test("a source is only closed on the run that observed it clear, never unconditionally", () => {
  // closeCleared takes a source, not an id, and closes every open row for it. Called
  // without having just seen the condition clear it would close a real, live incident.
  // So every call must sit directly inside the branch that means "clear": the nearest
  // enclosing block header (the closest earlier line with less indentation) must be
  // an `} else {` or an `if (!...)`. Structural on purpose: counting lines back to an
  // `else` breaks the first time someone writes a long comment above it, and a test
  // that fails on correct code is a test that gets deleted.
  const lines = src.split("\n");
  const indent = (l: string) => l.length - l.trimStart().length;
  const bad: string[] = [];
  lines.forEach((line, i) => {
    const m = line.match(/closeCleared\(\s*"([a-z_]+)"/);
    if (!m) return;
    const here = indent(line);
    let header = "";
    for (let j = i - 1; j >= 0; j--) {
      const t = lines[j].trim();
      if (t === "" || t.startsWith("//")) continue;
      if (indent(lines[j]) < here) { header = t; break; }
    }
    if (!/^\}\s*else\s*\{$/.test(header) && !/^if\s*\(\s*!/.test(header)) {
      bad.push(`${m[1]} (line ${i + 1}) is inside: ${header || "(top level)"}`);
    }
  });
  assert.deepEqual(bad, [], `closeCleared reached without a clear-condition guard:\n${bad.join("\n")}`);
});
