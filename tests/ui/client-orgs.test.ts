// The Partner tier is sold with client organizations; until 2026-10-02 nothing created one and the
// "+ Tenant" button opened the self-serve onboarding (an independent trial organization) instead.
//
//   node --experimental-strip-types --test tests/ui/client-orgs.test.ts
//
// What is pinned: the workspace calls the real create path and never the onboarding one, the button
// is shown only to a Partner whose organization can create clients, the console can set the allowance,
// and the SQL refuses everything it must refuse. The SQL itself was exercised in a rolled-back
// transaction against the live database (create, duplicate, bad industry, over allowance, non-Partner,
// chain, contributor, stranger and anon); the checks here keep the file honest about those guards.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const app = readFileSync(join(root, "app.html"), "utf8");
const admin = readFileSync(join(root, "admin.html"), "utf8");
const index = readFileSync(join(root, "index.html"), "utf8");
const migDir = join(root, "supabase", "migrations");
const mig = (needle: string) =>
  readdirSync(migDir).filter((f) => f.endsWith(".sql") && f.includes(needle)).map((f) => readFileSync(join(migDir, f), "utf8")).join("\n");
const fns = mig("partner_client_organization_functions");
const col = mig("partner_client_allowance_column");

test("the workspace creates client organizations through the real RPC", () => {
  assert.match(app, /cavscope_create_client_org/);
  assert.match(app, /cavscope_client_orgs/);
  assert.match(app, /create_client_org:\s*\{/);
});

test("the old Tenant button no longer opens the self-serve onboarding", () => {
  assert.doesNotMatch(app, /currentModalType === 'create_tenant'\)\s*\{[^}]*openOnboard/);
  assert.match(app, /type === 'create_tenant'\)\s*\{\s*Live\.beginClientOrg\(\)/);
});

test("in a live workspace the button is hidden unless the Partner can create clients", () => {
  assert.match(app, /id="btnCreateTenant"/);
  assert.match(app, /btn\.hidden = live && !can/);
  assert.match(app, /const can = !!\(this\.partner && this\.partner\.enabled\)/);
});

test("the workspace stops a create past the allowance before calling the backend", () => {
  assert.match(app, /\(p\.clients \|\| \[\]\)\.length >= p\.allowance/);
});

test("the console can set the allowance, and confirms first", () => {
  assert.match(admin, /cavscope_admin_set_partner_allowance/);
  assert.match(admin, /cavscope_admin_partner_allowances/);
  assert.match(admin, /case 'partner-allowance': setPartnerAllowance/);
  assert.match(admin, /async function setPartnerAllowance[\s\S]{0,700}window\.confirm/);
});

test("the SQL refuses a non-Partner, a missing flag, a chain, a bad name or industry, a duplicate and an over-allowance create", () => {
  for (const guard of [
    /partner_client_allowance is null/,
    /has_flag\(p_partner, 'client_management_enabled'\)/,
    /managed_by_org_id is not null/,
    /char_length\(v_name\)/,
    /from cavscope\.industries where key = v_industry/,
    /lower\(name\) = lower\(v_name\)/,
    /v_count >= v_partner\.partner_client_allowance/,
  ]) assert.match(fns, guard, String(guard));
});

test("creating a client needs executive or super admin on the Partner, and anon cannot call anything new", () => {
  assert.match(fns, /org_role\(p_partner_org_id\), ''\) not in \('executive', 'super_admin'\)/);
  for (const f of ["cavscope_create_client_org(bigint, text, text)", "cavscope_client_orgs(bigint)", "cavscope_admin_set_partner_allowance(bigint, integer)"]) {
    assert.match(fns, new RegExp(`revoke all on function public\\.${f.replace(/[()]/g, "\\$&")} from public, anon`), f);
  }
  assert.match(fns, /revoke all on function cavscope\.do_create_client_org\(bigint, text, text, bigint\) from public, anon, authenticated/);
});

test("past the allowance it refuses rather than giving extras away", () => {
  assert.match(fns, /all are in use\. Additional organizations are not available self-serve yet/);
});

test("Partner status is an explicit allowance a super admin sets, never guessed from the plan", () => {
  assert.match(col, /partner_client_allowance integer/);
  assert.match(col, /partner_client_allowance is null or partner_client_allowance >= 0/);
});

test("the landing page no longer calls client organization management unbuilt, but still says extra billing is", () => {
  assert.doesNotMatch(index, /Client organization management <span[^>]*>\(in development\)/);
  assert.doesNotMatch(index, /Multi-tenant client workspaces <span[^>]*>\(in development\)/);
  assert.match(index, /Expansion billing based on active client organizations <span[^>]*>\(in development\)/);
});
