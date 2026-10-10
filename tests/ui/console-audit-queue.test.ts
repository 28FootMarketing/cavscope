// Audit Queue section of the Super Admin Console (admin.html).
//
//   node --experimental-strip-types --test tests/ui/console-audit-queue.test.ts
//
// The panel promised the most recent runs and asked for 50, but the payload returned 8 of 260,
// the nav badge counted those 8, a browser scan looked like an HTTP one, a failed scan gave no
// reason, and a scan hung in `running` read as a healthy queue.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const html = readFileSync(join(root, "admin.html"), "utf8");
const mig = readFileSync(join(root, "supabase/migrations/20261010191647_admin_console_audit_queue_wiring.sql"), "utf8");

test("the nav badge counts work in flight, not the length of a capped list", () => {
  assert.match(html, /case 'audit-queue': return \(\(k\.assessments \|\| \{\}\)\.queued/);
  assert.doesNotMatch(html, /case 'audit-queue': return \(DATA\.recent_scans/);
});

test("each scan shows its engine, and a failure shows its reason", () => {
  assert.match(html, /r\.engine_version/);
  assert.match(html, /r\.error \|\| 'The engine did not record a reason\.'/);
});

test("a stalled scan is shown on the queue and warns on the Overview", () => {
  assert.match(html, /q\.stalled \? 'bad' : 'ok'/);
  assert.match(html, /q\.stalled > 0 \|\| q\.queued > 20/);
});

test("the panel says 50 because the payload returns 50", () => {
  assert.match(html, /The 50 most recent runs/);
  assert.match(mig, /limit 50\) r\),/);
  assert.match(mig, /'stalled'|''stalled''/);
  assert.match(mig, /expected exactly 1 match/);
});
