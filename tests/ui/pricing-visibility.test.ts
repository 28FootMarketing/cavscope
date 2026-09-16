// Public pricing tier visibility on index.html, and the matching admin toggles
// in app.html.
//
//   node --experimental-strip-types --test tests/ui/pricing-visibility.test.ts
//
// Partner-only is the intentional commercial default. The page must ship that
// way even when JS is off or muster_public_pricing() predates the `visible`
// key. The admin panel must not claim every tier is off just because the RPC
// has not been migrated yet.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");

function read(page: string) {
  return readFileSync(join(repoRoot, page), "utf8");
}

test("index.html hides MUSTER and Enterprise by default", () => {
  const html = read("index.html");
  assert.match(html, /id="cardMuster" hidden/);
  assert.match(html, /id="cardEnterprise" hidden/);
  assert.doesNotMatch(html, /id="cardPartner"[^>]*\bhidden\b/);
  assert.match(html, /id="pricingCount"[^>]*>One plan</);
  assert.match(html, /data-visible-count="1"/);
});

test("index.html applyVisibility keeps Partner when every toggle is off", () => {
  const html = read("index.html");
  const match = /function applyVisibility\(visible\) \{[\s\S]*?\n  \}/.exec(html);
  assert.ok(match, "applyVisibility not found in index.html");

  const hidden: Record<string, boolean> = {};
  const dataset: Record<string, string> = {};
  const countEl = { textContent: "", tip: "", setAttribute(_k: string, v: string) { this.tip = v; } };
  const doc = {
    getElementById(id: string) {
      if (id === "cardMuster" || id === "cardPartner" || id === "cardEnterprise") {
        return {
          get hidden() { return !!hidden[id]; },
          set hidden(v: boolean) { hidden[id] = v; },
        };
      }
      if (id === "pricingGrid") return { dataset };
      if (id === "pricingCount") return countEl;
      return null;
    },
  };

  new Function("document", `${match[0]}; applyVisibility({ muster: false, muster_partner: false, enterprise: false });`)(doc);

  assert.equal(hidden.cardMuster, true);
  assert.equal(hidden.cardPartner, false, "Partner must stay when every toggle is off");
  assert.equal(hidden.cardEnterprise, true);
  assert.equal(dataset.visibleCount, "1");
  assert.equal(countEl.textContent, "One plan");
});

test("index.html applyVisibility can show all three tiers", () => {
  const html = read("index.html");
  const match = /function applyVisibility\(visible\) \{[\s\S]*?\n  \}/.exec(html);
  assert.ok(match, "applyVisibility not found in index.html");

  const hidden: Record<string, boolean> = {};
  const dataset: Record<string, string> = {};
  const countEl = { textContent: "", tip: "", setAttribute(_k: string, v: string) { this.tip = v; } };
  const doc = {
    getElementById(id: string) {
      if (id === "cardMuster" || id === "cardPartner" || id === "cardEnterprise") {
        return {
          get hidden() { return !!hidden[id]; },
          set hidden(v: boolean) { hidden[id] = v; },
        };
      }
      if (id === "pricingGrid") return { dataset };
      if (id === "pricingCount") return countEl;
      return null;
    },
  };

  new Function("document", `${match[0]}; applyVisibility({ muster: true, muster_partner: true, enterprise: true });`)(doc);

  assert.equal(hidden.cardMuster, false);
  assert.equal(hidden.cardPartner, false);
  assert.equal(hidden.cardEnterprise, false);
  assert.equal(dataset.visibleCount, "3");
  assert.equal(countEl.textContent, "Three plans");
});

test("app.html Public Pricing panel defaults Partner on when visible is missing", () => {
  const html = read("app.html");
  assert.match(html, /setPricingVisibility/);
  assert.match(html, /muster_admin_set_pricing_visibility/);
  assert.match(
    html,
    /pricing\.visible\s*\?\s*!!pricing\.visible\[t\.key\]\s*:\s*t\.key === 'muster_partner'/,
  );
});

// The visibility surface was originally written as migration 049
// (20260911002553_muster_049_public_pricing_tier_visibility.sql). That file was
// committed but never applied to hjowfnzpomzxazmzywxw, so
// muster_admin_set_pricing_visibility() did not exist and every toggle in the
// admin console threw PGRST202 -- silently, because muster_public_pricing()
// returned no `visible` key either and index.html fell back to the same
// Partner-only default the toggles were supposed to produce. This test passed
// the whole time: it read a file, not the database. It now pins the migration
// that actually ran, and 049 was deleted so the directory keeps its stated
// invariant that every file in it was really applied.
test("the applied migration seeds Partner-only visibility and the CTA surface", () => {
  const sql = read("supabase/migrations/20260916012445_muster_pricing_cta_admin_control.sql");
  assert.match(sql, /show_muster\s+boolean not null default false/);
  assert.match(sql, /show_muster_partner\s+boolean not null default true/);
  assert.match(sql, /show_enterprise\s+boolean not null default false/);
  assert.match(sql, /muster_admin_set_pricing_visibility/);
  assert.match(sql, /'visible', jsonb_build_object/);
  assert.match(sql, /'cta', jsonb_build_object/);
  // An empty pricing section is a broken page; the RPC says so rather than
  // silently overriding the admin the way the client-side guard does.
  assert.match(sql, /at least one pricing tier must stay visible/);
});

test("the never-applied 049 migration file is gone", () => {
  assert.equal(
    existsSync(join(repoRoot, "supabase/migrations/20260911002553_muster_049_public_pricing_tier_visibility.sql")),
    false,
    "049 was superseded by the applied 20260916012445; a file for an unapplied version is the forward reference supabase/migrations/README.md warns about",
  );
});
