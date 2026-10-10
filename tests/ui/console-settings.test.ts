// Settings (feature-flag registry) section of the Super Admin Console (admin.html).
//
//   node --experimental-strip-types --test tests/ui/console-settings.test.ts
//
// Defaults, kill switches, plan gates, overrides and flag creation/removal changed what tenants
// can do and recorded nothing; the database let a switch be moved on a flag nothing reads (the
// page only disabled it); and an unknown key "saved" without changing a row.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const html = readFileSync(join(root, "admin.html"), "utf8");
const m1 = readFileSync(join(root, "supabase/migrations/20261010202032_flag_writers_audit_and_guards.sql"), "utf8");
const m2 = readFileSync(join(root, "supabase/migrations/20261010202101_admin_console_flag_changes_payload.sql"), "utf8");
const sql = m1.replace(/^--.*$/gm, "");

test("a flag nothing reads gets no plan gate and no override form, in the page", () => {
  assert.match(html, /data-act="flag-plan"[^>]*\$\{wired \? '' : 'disabled'\}/);
  assert.match(html, /\$\{wired \? `<form data-act="override-add"/);
  assert.match(html, /Overrides cannot be added: nothing reads this key/);
});

test("the database refuses the same things", () => {
  assert.equal((sql.match(/is read by nothing/g) || []).length, 3);
  assert.match(sql, /p_on and coalesce\(array_length\(f\.enforcement, 1\), 0\) = 0/);
  assert.match(sql, /no such flag %', p_key using errcode = 'P0002'/);
  assert.match(sql, /an override needs a reason of at least 8 characters/);
});

test("every flag writer records who changed what", () => {
  for (const a of ["Feature flag default changed", "Feature flag override set", "Feature flag override revoked",
    "Feature flag plan gate changed", "Feature flag kill switch changed", "Feature flag created", "Feature flag removed"]) {
    assert.ok(sql.includes(a), `no audit row for: ${a}`);
  }
});

test("setting an override replaces the row in place (and the migration holds no DELETE the MCP hangs on)", () => {
  assert.doesNotMatch(sql, /\bdelete\b/i);
  assert.match(sql, /update cavscope\.feature_flag_overrides/);
});

test("recent flag changes are shown, from the payload", () => {
  assert.match(html, /DATA\.flag_changes/);
  assert.match(html, /Recent flag changes/);
  assert.match(m2, /flag_changes/);
  assert.match(m2, /expected exactly 1 match/);
});
