// The landing page's pricing buttons (index.html).
//
//   node --experimental-strip-types --test tests/ui/landing-cta.test.ts
//
// Found 2026-10-10 by a cross-section check of the admin console. The page ignored the `cta`
// object that cavscope_public_pricing() returns and that Billing edits: it carried its own two
// Stripe Payment Links, a paused flag fixed at true, and a GHL intake URL that was still the
// placeholder https://forms.your-ghl-domain.example.com/... -- so the only visible card, "Become a
// CavScope Partner", linked to a host that does not exist, and nothing edited in Billing reached it.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const html = readFileSync(join(root, "index.html"), "utf8");

function fn(name: string): string {
  const a = html.indexOf(`function ${name}(`);
  assert.ok(a > 0, `${name} missing from index.html`);
  let depth = 0, i = html.indexOf("{", a);
  for (; i < html.length; i++) {
    if (html[i] === "{") depth++;
    else if (html[i] === "}" && --depth === 0) break;
  }
  return html.slice(a, i + 1);
}
const consts = ["FALLBACK_SALES_HREF", "FALLBACK_PARTNER_HREF", "FALLBACK_ENTERPRISE_HREF"]
  .map((n) => new RegExp(`const ${n} = '[^']+';`).exec(html)![0]).join("\n");
const resolveCta = new Function(`${consts}\n${fn("resolveCta")}\nreturn resolveCta;`)() as
  (cta: Record<string, unknown> | null, stage: string) => { muster: string; partner: string; enterprise: string };
const withSource = new Function(`${fn("withSource")}\nreturn withSource;`)() as
  (href: string, product: string, intent: string) => string;

const DB = {
  muster_self_serve_paused: true,
  muster_contact_url: "mailto:sales@28footsystems.com?subject=CavScope%20Interest",
  muster_seed_checkout_url: "https://buy.stripe.com/seed",
  muster_fruit_checkout_url: "https://buy.stripe.com/fruit",
  partner_contact_url: "mailto:sales@28footsystems.com?subject=CavScope%20Partner%20Inquiry",
  partner_seed_checkout_url: null,
  partner_fruit_checkout_url: null,
  partner_intake_url: null,
  enterprise_contact_url: "mailto:sales@28footsystems.com?subject=CavScope%20Enterprise%20Inquiry",
};

const code = html.replace(/<!--[\s\S]*?-->/g, "").replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\s*\/\/.*$/gm, "");

test("the page's code carries no placeholder host and no payment link of its own", () => {
  assert.doesNotMatch(code, /example\.com/);
  assert.doesNotMatch(code, /your-ghl-domain/);
  assert.doesNotMatch(code, /buy\.stripe\.com/);
  assert.doesNotMatch(code, /MUSTER_SELF_SERVE_PAUSED/);
});

test("the buttons are set from the cta object cavscope_public_pricing returns", () => {
  assert.match(html, /applyPricing\(data\.current_stage, data\.muster, data\.muster_partner, data\.visible \|\| DEFAULT_VISIBLE, data\.cta\)/);
});

test("while paused, every button goes to its sales contact (the state on file)", () => {
  const r = resolveCta(DB, "seed");
  assert.equal(r.muster, DB.muster_contact_url);
  assert.equal(r.partner, DB.partner_contact_url);
  assert.equal(r.enterprise, DB.enterprise_contact_url);
});

test("a destination edited in Billing is what the page uses", () => {
  const r = resolveCta({ ...DB, partner_contact_url: "mailto:partners@28footsystems.com" }, "seed");
  assert.equal(r.partner, "mailto:partners@28footsystems.com");
});

test("unpaused, the checkout for the current stage is used, then the intake, then the contact", () => {
  const live = { ...DB, muster_self_serve_paused: false, partner_seed_checkout_url: "https://buy.stripe.com/partner-seed" };
  assert.equal(resolveCta(live, "seed").muster, "https://buy.stripe.com/seed");
  assert.equal(resolveCta(live, "fruit").muster, "https://buy.stripe.com/fruit");
  assert.equal(resolveCta(live, "seed").partner, "https://buy.stripe.com/partner-seed");
  assert.equal(resolveCta({ ...live, partner_seed_checkout_url: null, partner_intake_url: "https://intake.28footsystems.com/partner" }, "seed").partner, "https://intake.28footsystems.com/partner");
  assert.equal(resolveCta({ ...live, partner_seed_checkout_url: null }, "seed").partner, DB.partner_contact_url);
});

test("a missing or failed read never produces a payment link or a dead one", () => {
  for (const cta of [null, {}, { muster_self_serve_paused: undefined }]) {
    const r = resolveCta(cta as never, "seed");
    for (const href of [r.muster, r.partner, r.enterprise]) assert.match(href, /^mailto:sales@28footsystems\.com/);
  }
  // an empty string in the database falls through rather than becoming href=""
  assert.equal(resolveCta({ ...DB, partner_contact_url: "  " }, "seed").partner, "mailto:sales@28footsystems.com?subject=CavScope%20Partner%20Inquiry");
});

test("source parameters are added to a form link, never to an email or a payment link", () => {
  assert.match(withSource("https://intake.28footsystems.com/partner", "muster_partner", "seed_signup"), /\?src=pricing_page&product=muster_partner&intent=seed_signup$/);
  assert.equal(withSource("mailto:sales@28footsystems.com", "muster_partner", "seed_signup"), "mailto:sales@28footsystems.com");
  assert.equal(withSource("https://buy.stripe.com/seed", "muster", "seed_signup"), "https://buy.stripe.com/seed");
});

test("the retired host is gone from the page's own code", () => {
  assert.doesNotMatch(code, /app\.muster\.partners/);
});

test("the customer-facing site verification tag is cavscope-verification, and the verifier still accepts the old name", () => {
  const onboarding = readFileSync(join(root, "onboarding.html"), "utf8");
  const verifier = readFileSync(join(root, "supabase/functions/cavscope-verify-site/index.ts"), "utf8");
  assert.match(onboarding, /<meta name="cavscope-verification" content=/);
  assert.doesNotMatch(onboarding, /name="muster-verification"/);
  assert.match(verifier, /\(\?:cavscope\|muster\)-verification/);
  assert.match(verifier, /expected: `<meta name="cavscope-verification"/);
});

test("downloads a customer saves are named for CavScope", () => {
  const app = readFileSync(join(root, "app.html"), "utf8");
  assert.doesNotMatch(app, /muster-assurance-|muster-client-roster-/);
  assert.match(app, /cavscope-assurance-/);
  assert.match(app, /cavscope-client-roster-/);
});
