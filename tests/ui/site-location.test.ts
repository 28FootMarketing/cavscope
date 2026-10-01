// A super admin can set where a site's laws are chosen for, and it wins.
//
//   node --experimental-strip-types --test tests/ui/site-location.test.ts
//
// cavscope.website_jurisdiction decides one location per site for both the
// tenant's workspace and the site's SITREP (20260929033108). Detection is a
// heuristic and has been wrong on a real site, and an agency may know its
// client's location better than anything on the page. Migration
// 20260929033647 adds an override a super admin sets in admin.html, which the
// resolver takes before anything the site or its organization says.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const sql = readFileSync(join(repoRoot, "supabase", "migrations", "20260929033647_site_jurisdiction_override.sql"), "utf8");
const admin = readFileSync(join(repoRoot, "admin.html"), "utf8");
const body = (name: string) => {
  const at = sql.indexOf(`create or replace function ${name}`);
  assert.ok(at >= 0, `${name} is not defined`);
  return sql.slice(at, sql.indexOf("$function$;", at));
};

test("the override is taken before the site and the organization, and does not borrow a detected region", () => {
  const r = body("cavscope.website_jurisdiction");
  const iOverride = r.indexOf("if v_ovr_country is not null then");
  const iSandbox = r.indexOf("if not v_override and not v_detected and v_sandbox then");
  assert.ok(iOverride > 0 && iSandbox > iOverride, "the override must be applied before the sandbox rule, so an ad-hoc audit can be given a location");
  assert.match(r, /v_country := v_ovr_country; v_region := v_ovr_region;/);
  assert.match(r, /'origin', case when v_override then 'override'/);
  assert.match(r, /Set by a CavScope administrator on %s, in place of what the site states\./);
});

test("only a super admin can read or set it, never anon, and every change is logged", () => {
  for (const name of ["public.muster_admin_site_jurisdictions", "public.muster_admin_set_site_jurisdiction"]) {
    assert.match(body(name), /if not cavscope\.is_super_admin\(\) then raise exception 'forbidden' using errcode = '42501'; end if;/);
  }
  assert.match(sql, /revoke all on function public\.muster_admin_site_jurisdictions\(\) from public, anon;/);
  assert.match(sql, /revoke all on function public\.muster_admin_set_site_jurisdiction\(bigint, text, text, text\) from public, anon;/);
  assert.match(sql, /admin jurisdiction RPC executable by anon/);
  const set = body("public.muster_admin_set_site_jurisdiction");
  assert.match(set, /insert into cavscope\.activity_events/);
  assert.match(set, /unknown country code/);
  assert.match(set, /unknown region % for country %/);
  assert.match(set, /reason is longer than 300 characters/);
});

test("the migration proved reports unchanged with no override, and probed one that wins", () => {
  assert.match(sql, /q_sitrep_jurisdiction changed output for websites/);
  assert.match(sql, /override did not win/);
  assert.match(sql, /SITREP did not follow the override/);
  assert.match(sql, /probe override was not rolled back/);
});

test("the console reads it as a side read and writes it through the shared write path", () => {
  assert.match(admin, /locations: \['cavscope_admin_site_jurisdictions'\]/);
  assert.match(admin, /await write\('cavscope_admin_set_site_jurisdiction',/);
  assert.match(admin, /const locForm = \{ site: '', country: '', region: '', note: '' \};/);
});

test("changing a real tenant's site confirms first; a sandbox site does not", () => {
  const set = admin.slice(admin.indexOf("  async function setSiteLocation() {"), admin.indexOf("  async function clearSiteLocation() {"));
  const clear = admin.slice(admin.indexOf("  async function clearSiteLocation() {"), admin.indexOf("  async function clearSiteLocation() {") + 900);
  for (const fn of [set, clear]) {
    assert.match(fn, /if \(!site\.sandbox && !window\.confirm\(/);
    assert.match(fn, /\{ render\(\); return; \}/, "a refused confirm must snap the form back");
  }
});
