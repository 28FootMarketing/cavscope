// The console Overview must say only what the payload can back (admin.html, Overview).
//
//   node --experimental-strip-types --test tests/ui/console-overview.test.ts
//
// Found 2026-10-10 by reading cavscope_admin_console() against the live catalog: the cron
// list was filtered to 'muster%' (so the browser sweep was unmonitored and an empty list
// read "0 healthy"), Risk Watch showed the sandbox's 70 findings beside a tile that
// excludes them, the Billing Webhook row was a fixed "Signature-verified", the org filter
// claimed to narrow every panel, and tooltips still named retired muster-* jobs.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const html = readFileSync(join(root, "admin.html"), "utf8");
const mig = readFileSync(join(root, "supabase/migrations/20261010183038_admin_console_overview_wiring.sql"), "utf8");

const overview = html.slice(html.indexOf("function kpiRow()"), html.indexOf("// ---- roster sections"));

test("an empty cron list is reported as a fault, never as healthy", () => {
  assert.match(overview, /\(stale\.length \|\| !cron\.length\) \? 'bad'/);
  assert.match(overview, /No scheduled jobs found/);
});

test("the Billing Webhook row is read from the payload, not fixed", () => {
  assert.match(overview, /bill\.stuck_grants/);
  assert.doesNotMatch(overview, /state: 'ok',\s*val: 'Signature-verified'/);
});

test("the scan queue warns on age as well as depth", () => {
  assert.match(overview, /oldest_queued_at && Date\.now\(\)/);
});

test("the Overview names no retired job or function", () => {
  assert.doesNotMatch(overview, /muster-/);
});

test("the filters claim only what they do", () => {
  assert.doesNotMatch(html, /Narrows every panel to one organization/);
  assert.doesNotMatch(html, /Window for the activity chart and the recent-scan table/);
  assert.match(overview, /Organization filter is on/);
});

test("migration: each edit is asserted to apply once, and the console uses cavscope names", () => {
  assert.match(mig, /expected exactly 1 match/);
  assert.match(mig, /like ''cavscope%''/);
  assert.match(mig, /not o\.is_admin_sandbox'\);/);
  assert.match(mig, /cavscope_public_pricing\(\)'\);/);
  assert.match(mig, /'billing'|''billing''/);
});

test("the two sections that were not-instrumented stubs name the cavscope schema, never the retired one", () => {
  const built = html.slice(html.indexOf("// ---- workspaces"), html.indexOf("const RENDER = {"));
  assert.ok(built.length > 2000, "workspaces and domain monitor not found");
  assert.doesNotMatch(built, /muster/i);
  assert.doesNotMatch(html, /const STUBS = \{|function renderStub\(/);
});
