// Where the answer already exists in CavScope's data, a form offers a list.
//
//   node --experimental-strip-types --test tests/ui/pick-lists.test.ts
//
// Standing rule from 2026-09-30 (CLAUDE.md, "Pick from what CavScope already
// knows"): a field whose answer is a catalog entry -- an industry, a country, a
// timezone, one of this workspace's websites, a teammate -- is a dropdown or a
// checklist, not a text box, so the same thing is always spelled the same way.
// Industry was free text until then, and the two beta signups on file said
// "Consulting" and "Business Operations Consulting".

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const read = (f: string) => readFileSync(join(root, f), "utf8");
const app = read("app.html");
const onboarding = read("onboarding.html");
const beta = read("beta.html");
const migration = read("supabase/migrations/20260930184023_industry_catalog.sql");

const catalog = [...migration.matchAll(/\(\s*'[a-z0-9_]+',\s*'([^']+)',\s*(\d+)\)/g)]
  .map((m) => [m[1], Number(m[2])] as const)
  .sort((a, b) => a[1] - b[1])
  .map(([label]) => label);

function bundled(src: string, file: string): string[] {
  const m = /const INDUSTRY_FALLBACK = \[([\s\S]*?)\];/.exec(src);
  assert.ok(m, `${file} has no INDUSTRY_FALLBACK`);
  return [...m[1].matchAll(/'([^']+)'/g)].map((x) => x[1]);
}

test("the catalog migration seeds the list the pages bundle, Other last", () => {
  assert.equal(catalog.length, 23);
  assert.equal(catalog.at(-1), "Other");
  for (const [src, file] of [[app, "app.html"], [onboarding, "onboarding.html"], [beta, "beta.html"]] as const) {
    assert.deepEqual(bundled(src, file), catalog, `${file}'s bundled industry list drifted from the migration`);
  }
  // beta.html also renders the options statically, so the form works with no script.
  const opts = [...beta.matchAll(/<option value="([^"]+)">/g)].map((m) => m[1].replace(/&amp;/g, "&"));
  assert.deepEqual(opts, catalog);
});

test("the catalog is read through a cavscope_* function anyone can call, never a new muster_* one", () => {
  assert.match(migration, /create or replace function public\.cavscope_industries\(\)/);
  assert.match(migration, /grant execute on function public\.cavscope_industries\(\) to anon, authenticated;/);
  assert.doesNotMatch(migration, /function public\.muster_/);
  for (const src of [app, onboarding]) assert.match(src, /rpc\('cavscope_industries'\)/);
  assert.match(beta, /\/rest\/v1\/rpc\/cavscope_industries/);
});

test("no page asks for an industry in a text box", () => {
  for (const [src, file] of [[app, "app.html"], [onboarding, "onboarding.html"], [beta, "beta.html"]] as const) {
    assert.doesNotMatch(src, /<input[^>]*(name="industry"|id="(ob|f)?[iI]ndustry")/, `${file} still types an industry`);
  }
  assert.match(app, /<select id="obIndustry" name="industry" required/);
  assert.match(onboarding, /<select id="fIndustry" required/);
  assert.match(beta, /<select id="industry" name="industry" required/);
  // Demo forms use the same list, not their own two different ones.
  assert.equal((app.match(/<select name="industry"[^>]*>\s*\$\{industryOptions\('', false\)\}/g) || []).length, 2);
});

test("a value typed before the list existed is kept and marked, never swapped", () => {
  for (const src of [app, onboarding]) {
    assert.match(src, /const legacy = cur && !industryLabels\.includes\(cur\);/);
    assert.match(src, /\(as entered before\)/);
  }
});

test("onboarding picks country and timezone from lists", () => {
  assert.match(onboarding, /\$\{countryField\(o\.country_code\)\}/);
  assert.match(onboarding, /rpc\('muster_countries'\)/);
  assert.doesNotMatch(onboarding, /Country code <span class="hint">\(2 letters/);
  assert.match(onboarding, /Intl\.supportedValuesOf\('timeZone'\)/);
});

test("a live workspace picks its website from the ones registered to it", () => {
  assert.match(app, /<select id="globalSiteSelect"[^>]*onchange="Live\.selectWebsite\(this\.value\)"/);
  assert.match(app, /async activateOrg\(o, websiteId\) \{/);
  // Until 2026-09-30 this was always websites[0], so a second site was unreachable.
  assert.doesNotMatch(app, /this\.website = \(o\.websites \|\| \[\]\)\[0\] \|\| null;/);
  const picker = app.slice(app.indexOf("renderSitePicker() {"), app.indexOf("async selectWebsite(id) {"));
  assert.match(picker, /input\.hidden = live;/);
  assert.match(picker, /sel\.hidden = !live;/);
});

test("SITREP recipients are picked from the team, with one field for outsiders", () => {
  const panel = app.slice(app.indexOf("renderSitrepDeliveryPanel() {"), app.indexOf("async setSitrepAlertPreference("));
  assert.match(panel, /<input type="checkbox" name="member"/);
  assert.match(panel, /name="extra"/);
  assert.doesNotMatch(panel, /<input name="recipients"/);
  assert.match(app, /\[\.\.\.f\.getAll\('member'\), \.\.\.String\(f\.get\('extra'\) \|\| ''\)\.split\(','\)\]/);
});
