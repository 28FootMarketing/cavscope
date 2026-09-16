// The Checkout Destinations panel in app.html's super admin console.
//
//   node --experimental-strip-types --test tests/ui/checkout-destinations.test.ts
//
// The point of this panel is that changing where a pricing-page button sends a
// visitor stops being a deploy. That only holds if every field posts a key the
// server actually accepts: muster_admin_set_checkout_url() rejects an unknown
// key with 22023, so one typo turns a control into a toast that always says
// "unknown CTA destination key" -- which is exactly how the visibility toggles
// spent their life calling a function that did not exist. The keys are pinned
// against the migration here so the two cannot drift apart silently.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const app = readFileSync(join(repoRoot, "app.html"), "utf8");
const migration = readFileSync(
  join(repoRoot, "supabase/migrations/20260916012445_muster_pricing_cta_admin_control.sql"),
  "utf8",
);

const EXPECTED_KEYS = [
  "muster_seed_checkout_url",
  "muster_fruit_checkout_url",
  "muster_contact_url",
  "partner_seed_checkout_url",
  "partner_fruit_checkout_url",
  "partner_intake_url",
  "partner_contact_url",
  "enterprise_contact_url",
];

test("the panel exists and every CTA key has a field", () => {
  assert.match(app, /<h3>Checkout Destinations<\/h3>/);
  for (const key of EXPECTED_KEYS) {
    assert.match(
      app,
      new RegExp(`key: '${key}'`),
      `no Checkout Destinations field for ${key}`,
    );
  }
});

test("every key the console posts is one the server accepts", () => {
  // The whitelist in muster_admin_set_checkout_url(), as applied.
  const whitelist = /if p_key not in \(([\s\S]*?)\) then/.exec(migration);
  assert.ok(whitelist, "key whitelist not found in the migration");
  const accepted = [...whitelist[1].matchAll(/'([a-z_]+)'/g)].map((m) => m[1]).sort();
  assert.deepEqual(accepted, [...EXPECTED_KEYS].sort(), "console keys and server whitelist disagree");

  // The panel renders its fields from the `key:` entries above through a
  // template literal, so the call site reads Live.setCheckoutUrl('${r.key}').
  // Any literal key spliced in anywhere else must also be on the whitelist.
  const posted = [...app.matchAll(/Live\.setCheckoutUrl\('([^']+)'/g)]
    .map((m) => m[1])
    .filter((k) => !k.startsWith("$"));
  for (const key of posted) {
    assert.ok(accepted.includes(key), `${key} is not accepted by muster_admin_set_checkout_url`);
  }
});

test("the console calls the RPCs that exist", () => {
  assert.match(app, /rpc\('muster_admin_set_checkout_url', \{ p_key: key, p_url: url \}\)/);
  assert.match(app, /rpc\('muster_admin_set_self_serve_paused', \{ p_paused: paused \}\)/);
  assert.match(app, /rpc\('muster_admin_set_pricing_visibility', \{ p_tier: tier, p_visible: on \}\)/);
  for (const fn of [
    "muster_admin_set_checkout_url",
    "muster_admin_set_self_serve_paused",
    "muster_admin_set_pricing_visibility",
  ]) {
    assert.match(migration, new RegExp(`create or replace function public\\.${fn}\\(`), `${fn} is not in the migration`);
  }
});

// CLAUDE.md: tooltips are mandatory on every interactive element. A URL field
// whose label does not say what the URL is for is the case that matters most
// here -- pasting a base-tier Payment Link into a Partner slot is a silent,
// money-losing mistake, and the tooltip is where that gets said.
test("every field and control in the panel carries a tooltip", () => {
  const panel = /<h3>Checkout Destinations<\/h3>[\s\S]*?\n          <div class="panel" style="margin-bottom:24px;">\n            <div class="panel-head"><div><h3>Feature Flags/.exec(app);
  assert.ok(panel, "could not isolate the Checkout Destinations panel");
  const body = panel[0];

  // Text inputs carry their own tooltip. A checkbox does not: every toggle in
  // this console is a bare <input type="checkbox"> inside
  // <label class="toggle-switch" data-tooltip="...">, so the tooltip is on the
  // label that wraps it. Both shapes are checked, neither is exempt.
  for (const tag of body.match(/<input\b[^>]*>/g) || []) {
    if (/type="checkbox"/.test(tag)) continue;
    assert.match(tag, /data-tooltip="/, `input without a tooltip: ${tag.slice(0, 90)}`);
  }
  for (const tag of body.match(/<label\b[^>]*>/g) || []) {
    assert.match(tag, /data-tooltip="/, `label without a tooltip: ${tag.slice(0, 90)}`);
  }
  assert.match(
    body,
    /<label class="toggle-switch" data-tooltip="[^"]+"><input type="checkbox"[^>]*onchange="Live\.setSelfServePaused\(!this\.checked\)"/,
    "the self-serve toggle must sit inside a label that carries its tooltip",
  );
});

test("the panel tells the truth about Partner Stripe links not existing", () => {
  assert.match(app, /No Partner price exists in Stripe yet/);
  assert.match(app, /tier=muster_partner/);
  // And about why un-pausing base-tier self-serve is gated.
  assert.match(app, /self_serve_onboarding flag/);
});
