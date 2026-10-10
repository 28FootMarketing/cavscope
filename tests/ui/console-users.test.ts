// Users & Roles section of the Super Admin Console (admin.html).
//
//   node --experimental-strip-types --test tests/ui/console-users.test.ts
//
// A platform role change granted access to every tenant's data and recorded nothing, and the
// database let the last super admin demote themselves; the page only warned. The 'admin' role
// is read by no function or policy, so the page must not imply it grants anything.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const html = readFileSync(join(root, "admin.html"), "utf8");
const mig = readFileSync(join(root, "supabase/migrations/20261010185944_platform_audit_and_role_change_guards.sql"), "utf8");
const users = html.slice(html.indexOf("function renderUsers()"), html.indexOf("// ---- reports"));

test("the role column does not imply 'admin' grants anything", () => {
  assert.match(users, /user and admin behave the same today/);
});

test("recent role changes are shown, from the payload", () => {
  assert.match(users, /DATA\.role_changes/);
  assert.match(users, /Recent role changes/);
});

test("your own row is marked", () => {
  assert.match(users, /u\.email === MY_EMAIL/);
});

test("migration: audit table is closed to browser roles, last super admin is protected, change is recorded", () => {
  assert.match(mig, /enable row level security/);
  assert.match(mig, /revoke all on cavscope\.platform_audit from anon, authenticated, public/);
  assert.match(mig, /cannot remove super_admin from the last super admin/);
  assert.match(mig, /v_old \|\| ' -> ' \|\| p_role/);
  assert.match(mig, /expected exactly 1 match/);
});
