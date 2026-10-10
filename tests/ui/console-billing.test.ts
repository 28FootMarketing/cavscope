// Billing section of the Super Admin Console (admin.html).
//
//   node --experimental-strip-types --test tests/ui/console-billing.test.ts
//
// cavscope_admin_set_checkout_url existed with no caller in the console, so the eight places the
// public pricing page sends a buyer were changeable only by SQL. The pricing writers recorded
// nothing, called an alias stage 5 drops, and self-serve could be un-paused with the Partner card
// showing and no Partner checkout link set.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const html = readFileSync(join(root, "admin.html"), "utf8");
const m1 = readFileSync(join(root, "supabase/migrations/20261010200718_pricing_admin_audit_and_unpause_guard.sql"), "utf8");
const m2 = readFileSync(join(root, "supabase/migrations/20261010200742_admin_console_pricing_changes_payload.sql"), "utf8");
const m3 = readFileSync(join(root, "supabase/migrations/20261010200812_self_serve_unpause_guard_fix_array_append.sql"), "utf8");
const billing = html.slice(html.indexOf("function renderBilling()"), html.indexOf("function renderIntegrations()"));

test("every destination the RPC accepts has a row in the console, and saving asks first", () => {
  for (const key of ["muster_seed_checkout_url", "muster_fruit_checkout_url", "muster_contact_url",
    "partner_seed_checkout_url", "partner_fruit_checkout_url", "partner_intake_url",
    "partner_contact_url", "enterprise_contact_url"]) {
    assert.ok(billing.includes(`'${key}'`), `no row for ${key}`);
    assert.ok(m1.includes(`'${key}'`), `RPC does not accept ${key}`);
  }
  assert.match(html, /cavscope_admin_set_checkout_url', \{ p_key: key, p_url: next \|\| null \}/);
  assert.match(html, /async function setCtaDestination[\s\S]*window\.confirm/);
});

test("a typed destination survives a re-render and is dropped only after a save", () => {
  assert.match(html, /if \(act === 'cta-set'\) return 'cta:'/);
  assert.match(html, /if \(saved\) \{ delete drafts\['cta:' \+ key\]; render\(\); \}/);
});

test("the notice no longer says cancellation is unhandled", () => {
  assert.doesNotMatch(billing, /is unhandled/);
});

test("pricing writers record who changed what and call the cavscope name, not the alias", () => {
  assert.equal((m1.match(/insert into cavscope\.platform_audit/g) || []).length, 4);
  assert.doesNotMatch(m1.replace(/^--.*$/gm, ''), /public\.muster_public_pricing/);
  assert.match(m2, /pricing_changes/);
  assert.match(billing, /DATA\.pricing_changes/);
});

test("un-pausing is refused while a shown tier has no checkout link, and the list is built with array_append", () => {
  assert.match(m3, /no checkout link is set for a tier the public page is showing/);
  assert.match(m3, /array_append\(v_missing, 'CavScope Partner \('/);
  assert.doesNotMatch(m3, /v_missing := v_missing \|\|/);
});
