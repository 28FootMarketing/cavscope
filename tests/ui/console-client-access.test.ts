// Client Access section of the Super Admin Console (admin.html).
//
//   node --experimental-strip-types --test tests/ui/console-client-access.test.ts

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const html = readFileSync(join(root, "admin.html"), "utf8");
const mig = readFileSync(join(root, "supabase/migrations/20261010184136_partner_allowance_guards.sql"), "utf8");
const row = html.slice(html.indexOf("function partnerAllowanceRow("), html.indexOf("function clientAccessCard("));

test("an allowance that cannot be used says so instead of reading as a working Partner", () => {
  assert.match(row, /client_management_enabled/);
  assert.match(row, /allowance set, creation is off/);
  assert.match(row, /resolvedForOrg\(cmFlag, o\)/);
});

test("the sandbox cannot be given an allowance in the page either", () => {
  assert.match(row, /locked = isClient \|\| !!o\.is_admin_sandbox/);
});

test("the page no longer calls client_management_enabled unwired", () => {
  assert.doesNotMatch(html, /An unwired entitlement \(client_management_enabled/);
});

test("migration: the database refuses a client or the sandbox, records the old value, skips no-ops", () => {
  assert.match(mig, /itself a client of a Partner/);
  assert.match(mig, /internal sandbox is not a customer/);
  assert.match(mig, /coalesce\(v_old::text, 'none'\)/);
  assert.match(mig, /v_old is distinct from p_allowance/);
});
