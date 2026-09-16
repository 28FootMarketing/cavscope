// Public pricing CTA destinations on index.html.
//
//   node --experimental-strip-types --test tests/ui/pricing-cta.test.ts
//
// Partner is the only card the pricing page shows by default (see
// tests/ui/pricing-visibility.test.ts), so its CTA is the page's entire
// conversion path. Ways it has broken or could break:
//
//   1. It pointed at https://forms.your-ghl-domain.example.com/... -- a
//      placeholder host that does not resolve. Every click died at DNS and
//      nothing in tests/ pinned the constant.
//   2. Reaching for one of the base-tier Stripe Payment Links to fill the gap.
//      Those carry metadata {tier: muster} at $97/$197; Partner is $197/$497 on
//      a different plan. muster-stripe-webhook reads that metadata to pick the
//      plan, so such a link would undercharge the buyer AND provision them the
//      base tier.
//   3. Now that destinations are admin-editable and arrive from
//      muster_public_pricing().cta, a bad or placeholder value stored in the
//      database reaching the page unvalidated. The page applies the same rule
//      to a stored value as to a hardcoded one -- the database is the source of
//      truth, not automatically well-formed. muster.is_valid_cta_destination()
//      is the server-side twin of isRealHttpsUrl().
//
// Partner Stripe Payment Links still do not exist -- muster.commercial_pricing
// has stripe_price_id null for muster_partner on both stages -- so today every
// card falls through to the sales mailto, which is a destination that works.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const html = readFileSync(join(repoRoot, "index.html"), "utf8");

// The base-tier links, which must never be a Partner CTA destination.
const BASE_TIER_LINKS = [
  "https://buy.stripe.com/eVqbJ26yL2hw3gL2x3gIo0t",
  "https://buy.stripe.com/bJeeVe5uHaO2bNhb3zgIo0u",
];

const PLACEHOLDER = "https://forms.your-ghl-domain.example.com/muster-partner-signup";

const FALLBACK_CONSTS = [
  "STRIPE_MUSTER_SEED_PAYMENT_LINK",
  "STRIPE_MUSTER_FRUIT_PAYMENT_LINK",
  "MUSTER_PAUSED_CONTACT_HREF",
  "ENTERPRISE_CONTACT_HREF",
  "STRIPE_PARTNER_SEED_PAYMENT_LINK",
  "STRIPE_PARTNER_FRUIT_PAYMENT_LINK",
  "GHL_PARTNER_SIGNUP_URL",
  "PARTNER_CONTACT_HREF",
];

const FNS = [
  "baseTierCheckoutLinks",
  "isRealHttpsUrl",
  "isUsableContactHref",
  "pickCheckoutUrl",
  "pickContactHref",
  "buildGhlUrl",
  "partnerCheckout",
  "musterCheckout",
  "enterpriseCheckout",
];

function extract(name: string) {
  const re = new RegExp(`function ${name}\\(.*?\\n  \\}`, "s");
  const m = re.exec(html);
  assert.ok(m, `${name} not found in index.html`);
  return m[0];
}

type Target = { href: string; tooltip: string };
type Page = {
  partner: (isSeed: boolean) => Target;
  muster: (isSeed: boolean) => Target;
  enterprise: () => Target;
  isRealHttpsUrl: (v: unknown) => boolean;
  isUsableContactHref: (v: unknown) => boolean;
};

// Builds the page's CTA resolution with a given muster_public_pricing().cta
// payload. `{}` is the no-network case: every constant falls back.
function loadPage(cta: Record<string, unknown> = {}, constOverrides: Record<string, string> = {}): Page {
  const MUSTER_SELF_SERVE_PAUSED = /const MUSTER_SELF_SERVE_PAUSED = (true|false);/.exec(html);
  assert.ok(MUSTER_SELF_SERVE_PAUSED, "MUSTER_SELF_SERVE_PAUSED not found");

  const declared = FALLBACK_CONSTS.map((name) => {
    if (name in constOverrides) return `const ${name} = ${JSON.stringify(constOverrides[name])};`;
    const m = new RegExp(`const ${name} = '([^']*)';`).exec(html);
    assert.ok(m, `${name} not found in index.html`);
    return `const ${name} = ${JSON.stringify(m[1])};`;
  });

  const src = [
    ...declared,
    `const MUSTER_SELF_SERVE_PAUSED = ${MUSTER_SELF_SERVE_PAUSED[1]};`,
    `let CTA = ${JSON.stringify(cta)};`,
    ...FNS.map(extract),
    `return { partner: partnerCheckout, muster: musterCheckout, enterprise: enterpriseCheckout,
              isRealHttpsUrl, isUsableContactHref };`,
  ].join("\n");
  return new Function(src)() as Page;
}

function everyShippedTarget(page: Page): Target[] {
  return [page.partner(true), page.partner(false), page.muster(true), page.muster(false), page.enterprise()];
}

test("no CTA ever resolves to a placeholder or dead host", () => {
  const cases = [
    {},
    // A placeholder that somehow reached the database must not reach the page.
    {
      partner_seed_checkout_url: PLACEHOLDER,
      partner_fruit_checkout_url: PLACEHOLDER,
      partner_intake_url: PLACEHOLDER,
      partner_contact_url: "https://your-domain.example.com/contact",
      muster_seed_checkout_url: "http://buy.stripe.com/insecure",
      muster_contact_url: "javascript:alert(1)",
      enterprise_contact_url: "not a url",
      muster_self_serve_paused: false,
    },
  ];
  for (const cta of cases) {
    for (const { href } of everyShippedTarget(loadPage(cta))) {
      assert.doesNotMatch(href, /example\.(com|net|org)\b/, `placeholder host in ${href}`);
      assert.doesNotMatch(href, /your-[a-z-]*domain/, `placeholder host in ${href}`);
      assert.doesNotMatch(href, /^javascript:/i, `unsafe scheme in ${href}`);
      assert.ok(
        href.startsWith("https://") || href.startsWith("mailto:"),
        `CTA must be https or mailto, got ${href}`,
      );
    }
  }
});

test("a stored placeholder falls back to the working destination, it does not blank the button", () => {
  const page = loadPage({
    partner_seed_checkout_url: PLACEHOLDER,
    partner_intake_url: PLACEHOLDER,
  });
  assert.match(page.partner(true).href, /^mailto:sales@28footsystems\.com/);
});

test("the Partner CTA never reuses a base-tier Stripe Payment Link", () => {
  // Not from the constants...
  for (const { href } of [loadPage().partner(true), loadPage().partner(false)]) {
    for (const link of BASE_TIER_LINKS) assert.notEqual(href, link);
  }
  // ...and not from a value typed into the admin console either. This one is
  // only caught by a human reading the tier metadata, so pin it here.
  const page = loadPage({
    partner_seed_checkout_url: BASE_TIER_LINKS[0],
    partner_fruit_checkout_url: BASE_TIER_LINKS[1],
  });
  for (const isSeed of [true, false]) {
    const { href } = page.partner(isSeed);
    for (const link of BASE_TIER_LINKS) {
      assert.notEqual(
        href,
        link,
        "a base-tier link in a Partner slot undercharges the buyer and provisions the wrong tier",
      );
    }
  }
  // And never as a hardcoded Partner constant.
  for (const link of BASE_TIER_LINKS) {
    assert.doesNotMatch(
      html,
      new RegExp(`const STRIPE_PARTNER_(SEED|FRUIT)_PAYMENT_LINK = '${link.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}'`),
    );
  }
});

test("with nothing stored, all three CTAs are the sales mailto and say so", () => {
  const page = loadPage();
  for (const t of everyShippedTarget(page)) {
    assert.match(t.href, /^mailto:sales@28footsystems\.com/);
  }
  assert.match(page.partner(true).tooltip, /Emails 28 Foot Systems/);
  assert.match(page.muster(true).tooltip, /Self-serve signup is paused/);
  assert.match(page.enterprise().tooltip, /Enterprise discovery/);
  assert.doesNotMatch(page.partner(true).tooltip, /Opens Stripe checkout|Opens a short intake/);
});

test("a stored Stripe Partner link takes priority, per stage", () => {
  const page = loadPage({
    partner_seed_checkout_url: "https://buy.stripe.com/partner_seed",
    partner_fruit_checkout_url: "https://buy.stripe.com/partner_fruit",
    partner_intake_url: "https://forms.real-ghl-host.dev/muster-partner-signup",
  });
  assert.equal(page.partner(true).href, "https://buy.stripe.com/partner_seed");
  assert.equal(page.partner(false).href, "https://buy.stripe.com/partner_fruit");
  assert.match(page.partner(true).tooltip, /Stripe checkout/);
});

test("a stored GHL form is used when Stripe links are absent, carrying the tag params", () => {
  const page = loadPage({ partner_intake_url: "https://forms.real-ghl-host.dev/muster-partner-signup" });
  const seed = new URL(page.partner(true).href);
  assert.equal(seed.searchParams.get("src"), "pricing_page");
  assert.equal(seed.searchParams.get("product"), "muster_partner");
  assert.equal(seed.searchParams.get("intent"), "seed_signup");
  assert.equal(new URL(page.partner(false).href).searchParams.get("intent"), "fruit_signup");
  assert.match(page.partner(true).tooltip, /short intake/);
});

test("base tier follows muster_self_serve_paused, per stage", () => {
  const paused = loadPage({ muster_self_serve_paused: true });
  assert.match(paused.muster(true).href, /^mailto:/);

  const live = loadPage({ muster_self_serve_paused: false });
  assert.equal(live.muster(true).href, BASE_TIER_LINKS[0]);
  assert.equal(live.muster(false).href, BASE_TIER_LINKS[1]);
  assert.match(live.muster(true).tooltip, /Stripe checkout/);

  // Un-paused but with no usable link: still a mailto, never a blank button.
  const broken = loadPage(
    { muster_self_serve_paused: false },
    { STRIPE_MUSTER_SEED_PAYMENT_LINK: "", STRIPE_MUSTER_FRUIT_PAYMENT_LINK: "" },
  );
  assert.match(broken.muster(true).href, /^mailto:/);
});

test("stored contact addresses override the constants", () => {
  const page = loadPage({
    muster_contact_url: "mailto:hello@muster.partners?subject=MUSTER",
    partner_contact_url: "mailto:partners@muster.partners",
    enterprise_contact_url: "https://cal.muster.partners/enterprise",
  });
  assert.equal(page.muster(true).href, "mailto:hello@muster.partners?subject=MUSTER");
  assert.equal(page.partner(true).href, "mailto:partners@muster.partners");
  assert.equal(page.enterprise().href, "https://cal.muster.partners/enterprise");
});

test("isRealHttpsUrl and isUsableContactHref reject placeholders, http and junk", () => {
  const { isRealHttpsUrl, isUsableContactHref } = loadPage();

  const junk = [
    "", "   ", "not a url", "http://buy.stripe.com/x", "javascript:alert(1)",
    PLACEHOLDER, "https://your-domain.dev/x", "https://example.com/x",
    "https://foo.example.org/x", "https://foo.test/x", "https://foo.invalid/x",
    "https://foo.localhost/x", null, undefined, 42,
  ];
  for (const bad of junk) {
    assert.equal(isRealHttpsUrl(bad), false, `isRealHttpsUrl(${String(bad)})`);
    assert.equal(isUsableContactHref(bad), false, `isUsableContactHref(${String(bad)})`);
  }

  for (const good of ["https://buy.stripe.com/x", "https://forms.muster.partners/signup"]) {
    assert.equal(isRealHttpsUrl(good), true, good);
    assert.equal(isUsableContactHref(good), true, good);
  }

  // mailto is a contact destination only, never a checkout link.
  for (const m of ["mailto:sales@28footsystems.com", "mailto:sales@28footsystems.com?subject=MUSTER%20Interest"]) {
    assert.equal(isUsableContactHref(m), true, m);
    assert.equal(isRealHttpsUrl(m), false, m);
  }
});

test("every CTA has a working href in markup, before any JS runs", () => {
  for (const id of ["musterCta", "partnerCta", "enterpriseCta"]) {
    const m = new RegExp(`<a[^>]*id="${id}"[^>]*>`).exec(html);
    assert.ok(m, `${id} anchor not found`);
    assert.match(m[0], /href="mailto:sales@28footsystems\.com/, `${id} has no no-JS fallback href`);
    assert.match(m[0], /data-tooltip="/, `${id} has no tooltip`);
  }
});
