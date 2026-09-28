// The design tokens, tested against the pages actually shipped.
//
//   node --experimental-strip-types --test tests/ui/design-tokens.test.ts
//
// assets/tokens.css is the source of truth; every page carries an inlined copy
// between the muster:tokens markers, written there by tools/tokens/sync.mjs.
// Inlining is deliberate -- the pages are self-contained, and a linked
// stylesheet would give all of them a shared way to render unstyled. The cost of
// that choice is one copy per page, and these tests are what make the copies safe.
//
// Before this existed the copies had already drifted, in the quiet way: --rose
// was #f6516a on the landing page and #f43f5e on the other five, --text-muted
// and --teal-glow split the same way, and --font-mono had a good fallback stack
// on two pages and a bare `monospace` on five. Nothing looked broken. That is
// the failure mode worth a test -- a product that sells assurance auditing
// should not ship two slightly different reds for the same meaning.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");

const PAGES = [
  "index.html",
  "app.html",
  "signin.html",
  "onboarding.html",
  "sitrep.html",
  "sitrep-sample.html",
  "admin.html",
  "privacy.html",
  "beta.html",
];

const read = (p: string) => readFileSync(join(ROOT, p), "utf8");

function declarations(css: string): Map<string, string> {
  const out = new Map<string, string>();
  for (const [, name, value] of css.matchAll(/(--[a-z0-9-]+)\s*:\s*([^;]+);/g)) {
    out.set(name, value.trim());
  }
  return out;
}

function tokenRegion(html: string): string {
  const start = html.indexOf("/* muster:tokens:start");
  const end = html.indexOf("/* muster:tokens:end */");
  assert.notEqual(start, -1, "page has no muster:tokens:start marker");
  assert.notEqual(end, -1, "page has no muster:tokens:end marker");
  return html.slice(start, end);
}

const canonical = declarations(read("assets/tokens.css"));

test("assets/tokens.css defines a non-trivial set, so an empty parse cannot pass", () => {
  // Every assertion below is satisfied by an empty map. This is the floor that
  // makes the rest mean something.
  assert.ok(canonical.size >= 30, `expected 30+ tokens, parsed ${canonical.size}`);
  for (const meaning of ["--bg", "--text", "--teal", "--rose", "--font-sans"]) {
    assert.ok(canonical.has(meaning), `missing ${meaning}`);
  }
});

for (const page of PAGES) {
  test(`${page} carries the canonical token block, unmodified`, () => {
    const found = declarations(tokenRegion(read(page)));
    assert.deepEqual(
      Object.fromEntries([...found].sort()),
      Object.fromEntries([...canonical].sort()),
      `${page} has drifted from assets/tokens.css -- run: node tools/tokens/sync.mjs`,
    );
  });

  test(`${page} declares no token outside the generated region`, () => {
    // A second :root elsewhere in the page would re-introduce exactly the drift
    // the generated region removes, and would win or lose by source order.
    const html = read(page);
    const outside = html.replace(tokenRegion(html), "");
    const styleOnly = outside.slice(outside.indexOf("<style>"), outside.indexOf("</style>"));
    const strays = [...declarations(styleOnly).keys()];
    assert.deepEqual(strays, [], `${page} declares tokens outside the generated block: ${strays.join(", ")}`);
  });

  test(`${page} resolves every var() it references`, () => {
    // The point of the whole exercise. A page referencing a token no longer in
    // the canonical set renders with the property dropped, silently.
    const html = read(page);
    const used = new Set([...html.matchAll(/var\((--[a-z0-9-]+)/g)].map((m) => m[1]));
    assert.ok(used.size > 0, `${page} references no tokens at all, which cannot be right`);
    const unresolved = [...used].filter((t) => !canonical.has(t));
    assert.deepEqual(unresolved, [], `${page} references undefined tokens: ${unresolved.join(", ")}`);
  });
}

test("one meaning has one value across the whole product", () => {
  // Stated as its own test because this is the defect that was actually
  // shipping, and a regression here is invisible in a browser.
  const perPage = PAGES.map((p) => ({ page: p, tokens: declarations(tokenRegion(read(p))) }));
  for (const [name, value] of canonical) {
    for (const { page, tokens } of perPage) {
      assert.equal(tokens.get(name), value, `${name} is "${tokens.get(name)}" on ${page} but "${value}" in assets/tokens.css`);
    }
  }
});

test("no token is defined in terms of a token that does not exist", () => {
  for (const [name, value] of canonical) {
    for (const [, ref] of value.matchAll(/var\((--[a-z0-9-]+)/g)) {
      assert.ok(canonical.has(ref), `${name} references ${ref}, which is not defined`);
    }
  }
});
