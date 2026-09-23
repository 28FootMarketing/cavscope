// Public pricing tier visibility on index.html, and the matching admin toggles
// in admin.html (app.html's in-app console owned them until 2026-09-23).
//
//   node --experimental-strip-types --test tests/ui/pricing-visibility.test.ts
//
// Partner-only is the intentional commercial default. The page must ship that
// way even when JS is off or muster_public_pricing() predates the `visible`
// key. The admin panel must not claim every tier is off just because the RPC
// has not been migrated yet.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
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

test("admin.html pricing panel defaults Partner on when visible is missing", () => {
  // Reading a missing key as "shown" made the console claim all three tiers
  // were live while index.html, correctly, showed Partner alone.
  const html = read("admin.html");
  assert.match(html, /setPricingVisibility/);
  assert.match(html, /muster_admin_set_pricing_visibility/);
  assert.match(
    html,
    /pricing\.visible\s*\?\s*!!pricing\.visible\[t\.key\]\s*:\s*t\.key === 'muster_partner'/,
  );
  assert.doesNotMatch(html, /visible\[t\.key\] !== false/);
});

test("migration seeds Partner-only visibility", () => {
  const sql = read("supabase/migrations/20260911002553_muster_049_public_pricing_tier_visibility.sql");
  assert.match(sql, /show_muster boolean not null default false/);
  assert.match(sql, /show_muster_partner boolean not null default true/);
  assert.match(sql, /show_enterprise boolean not null default false/);
  assert.match(sql, /muster_admin_set_pricing_visibility/);
  assert.match(sql, /'visible', jsonb_build_object/);
});
