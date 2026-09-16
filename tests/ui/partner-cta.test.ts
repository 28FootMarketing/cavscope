// MUSTER Partner CTA destination on index.html.
//
//   node --experimental-strip-types --test tests/ui/partner-cta.test.ts
//
// Partner is the only card the pricing page shows by default (see
// tests/ui/pricing-visibility.test.ts), so its CTA is the page's entire
// conversion path. Two ways it has broken or could break:
//
//   1. It pointed at https://forms.your-ghl-domain.example.com/... -- a
//      placeholder host that does not resolve. Every click 404'd at DNS and
//      nothing failed to catch it.
//   2. Reaching for one of the base-tier Stripe Payment Links to fill the gap.
//      Those carry metadata {tier: muster}, and Partner is a different price
//      ($197/$497 vs $97/$197) on a different plan. That link would undercharge
//      the buyer and make muster-stripe-webhook grant them the base tier.
//
// Partner Stripe Payment Links do not exist yet -- muster.commercial_pricing
// has stripe_price_id null for muster_partner on both stages. Until they do,
// the CTA falls back to the sales mailto, which is a destination that works.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const html = readFileSync(join(repoRoot, "index.html"), "utf8");

// The base-tier links, which must never be the Partner CTA's destination.
const BASE_TIER_LINKS = [
  "https://buy.stripe.com/eVqbJ26yL2hw3gL2x3gIo0t",
  "https://buy.stripe.com/bJeeVe5uHaO2bNhb3zgIo0u",
];

function extract(name: string) {
  const re = new RegExp(`function ${name}\\(.*?\\n  \\}`, "s");
  const m = re.exec(html);
  assert.ok(m, `${name} not found in index.html`);
  return m[0];
}

function loadPartnerCheckout(overrides: Record<string, string> = {}) {
  const consts = [
    "STRIPE_PARTNER_SEED_PAYMENT_LINK",
    "STRIPE_PARTNER_FRUIT_PAYMENT_LINK",
    "GHL_PARTNER_SIGNUP_URL",
    "PARTNER_CONTACT_HREF",
  ];
  const declared = consts.map((name) => {
    if (name in overrides) return `const ${name} = ${JSON.stringify(overrides[name])};`;
    const m = new RegExp(`const ${name} = '([^']*)';`).exec(html);
    assert.ok(m, `${name} not found in index.html`);
    return `const ${name} = ${JSON.stringify(m[1])};`;
  });
  const src = [
    ...declared,
    extract("isRealHttpsUrl"),
    extract("buildGhlUrl"),
    extract("partnerCheckout"),
    "return partnerCheckout;",
  ].join("\n");
  return new Function(src)() as (isSeed: boolean) => { href: string; tooltip: string };
}

test("the shipped Partner CTA never resolves to a placeholder or dead host", () => {
  const partnerCheckout = loadPartnerCheckout();
  for (const isSeed of [true, false]) {
    const { href } = partnerCheckout(isSeed);
    assert.doesNotMatch(href, /example\.(com|net|org)\b/, `placeholder host in ${href}`);
    assert.doesNotMatch(href, /your-[a-z-]*domain/, `placeholder host in ${href}`);
    assert.ok(
      href.startsWith("https://") || href.startsWith("mailto:"),
      `Partner CTA must be https or mailto, got ${href}`,
    );
  }
});

test("the Partner CTA never reuses a base-tier Stripe Payment Link", () => {
  const partnerCheckout = loadPartnerCheckout();
  for (const isSeed of [true, false]) {
    const { href } = partnerCheckout(isSeed);
    for (const link of BASE_TIER_LINKS) {
      assert.notEqual(href, link, "base-tier link would undercharge and mis-provision Partner");
    }
  }
  // The same links must not be wired in as the Partner constants either.
  for (const link of BASE_TIER_LINKS) {
    assert.doesNotMatch(
      html,
      new RegExp(`const STRIPE_PARTNER_(SEED|FRUIT)_PAYMENT_LINK = '${link.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}'`),
    );
  }
});

test("today the Partner CTA is the sales mailto, and says so", () => {
  const partnerCheckout = loadPartnerCheckout();
  for (const isSeed of [true, false]) {
    const { href, tooltip } = partnerCheckout(isSeed);
    assert.match(href, /^mailto:sales@28footsystems\.com/);
    assert.match(tooltip, /Emails 28 Foot Systems/);
    assert.doesNotMatch(tooltip, /checkout\.|Opens a short intake/);
  }
});

test("a real Stripe Partner link takes priority, per stage", () => {
  const partnerCheckout = loadPartnerCheckout({
    STRIPE_PARTNER_SEED_PAYMENT_LINK: "https://buy.stripe.com/partner_seed",
    STRIPE_PARTNER_FRUIT_PAYMENT_LINK: "https://buy.stripe.com/partner_fruit",
    GHL_PARTNER_SIGNUP_URL: "https://forms.real-ghl.example-free.dev/muster-partner-signup",
  });
  assert.equal(partnerCheckout(true).href, "https://buy.stripe.com/partner_seed");
  assert.equal(partnerCheckout(false).href, "https://buy.stripe.com/partner_fruit");
  assert.match(partnerCheckout(true).tooltip, /Stripe checkout/);
});

test("a real GHL form is used when Stripe links are absent, carrying the tag params", () => {
  const partnerCheckout = loadPartnerCheckout({
    GHL_PARTNER_SIGNUP_URL: "https://forms.real-ghl-host.dev/muster-partner-signup",
  });
  const seed = new URL(partnerCheckout(true).href);
  assert.equal(seed.searchParams.get("src"), "pricing_page");
  assert.equal(seed.searchParams.get("product"), "muster_partner");
  assert.equal(seed.searchParams.get("intent"), "seed_signup");
  assert.equal(new URL(partnerCheckout(false).href).searchParams.get("intent"), "fruit_signup");
  assert.match(partnerCheckout(true).tooltip, /short intake/);
});

test("isRealHttpsUrl rejects placeholders, http and junk", () => {
  const partnerCheckout = loadPartnerCheckout();
  const src = [extract("isRealHttpsUrl"), "return isRealHttpsUrl;"].join("\n");
  const isRealHttpsUrl = new Function(src)() as (v: unknown) => boolean;
  assert.ok(partnerCheckout);

  for (const bad of [
    "",
    "   ",
    "not a url",
    "http://buy.stripe.com/x",
    "mailto:sales@28footsystems.com",
    "https://forms.your-ghl-domain.example.com/muster-partner-signup",
    "https://your-domain.dev/x",
    "https://example.com/x",
    "https://foo.example.org/x",
    "https://foo.test/x",
    "https://foo.invalid/x",
    "https://foo.localhost/x",
    null,
    undefined,
    42,
  ]) {
    assert.equal(isRealHttpsUrl(bad), false, `expected ${String(bad)} to be rejected`);
  }

  for (const good of [
    "https://buy.stripe.com/eVqbJ26yL2hw3gL2x3gIo0t",
    "https://forms.muster.partners/muster-partner-signup",
  ]) {
    assert.equal(isRealHttpsUrl(good), true, `expected ${good} to be accepted`);
  }
});

test("the CTA has a working href in markup, before any JS runs", () => {
  const m = /<a[^>]*id="partnerCta"[^>]*>/.exec(html);
  assert.ok(m, "partnerCta anchor not found");
  assert.match(m[0], /href="mailto:sales@28footsystems\.com/);
  assert.match(m[0], /data-tooltip="/);
});
