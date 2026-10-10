// Organizations section of the Super Admin Console (admin.html).
//
//   node --experimental-strip-types --test tests/ui/console-organizations.test.ts
//
// The roster showed a client organization as an ordinary tenant (nothing said whose it was),
// showed sites without the limit they count against, and a downgrade confirm never mentioned
// that the tenant would be over its new limit. The plan-change audit row also recorded only
// the new plan.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const html = readFileSync(join(root, "admin.html"), "utf8");
const mig = readFileSync(join(root, "supabase/migrations/20261010183712_admin_console_organizations_wiring.sql"), "utf8");
const roster = html.slice(html.indexOf("function renderOrganizations()"), html.indexOf("// ---- client access"));

test("a client organization says whose it is", () => {
  assert.match(roster, /Client of \$\{escapeHtml\(o\.managed_by\)\}/);
  assert.match(roster, /client_orgs > 0/);
});

test("sites are shown against the plan limit", () => {
  assert.match(roster, /of \$\{num\(o\.website_limit\)\}/);
});

test("a downgrade over the new limit is named in the confirm, and says nothing is deleted", () => {
  const fn = html.slice(html.indexOf("async function setPlan("), html.indexOf("async function setPartnerAllowance"));
  assert.match(fn, /DATA\.plan_limits/);
  assert.match(fn, /Nothing is deleted or disabled/);
  assert.match(fn, /window\.confirm/);
});

test("migration: payload edits assert once; set_plan records the old plan, refuses unknown, skips no-ops", () => {
  assert.match(mig, /expected exactly 1 match/);
  assert.match(mig, /managed_by/);
  assert.match(mig, /plan_limits/);
  assert.match(mig, /v_old \|\| ' -> ' \|\| p_plan/);
  assert.match(mig, /unknown plan/);
  assert.match(mig, /v_old is distinct from p_plan/);
});
