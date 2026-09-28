// index.html's two "sign in to the workspace" CTAs.
//
//   node --experimental-strip-types --test tests/auth/workspace-cta.test.ts
//
// cavscope.28footsystems.com has no separate app host (see middleware.js), so
// the CTA has to stay on that origin and go to /signin. Everywhere else the
// page is served -- muster.partners, the *.muster.28footsystems.com hosts --
// it still hops to the legacy app.muster.partners origin, unchanged.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const html = readFileSync(join(ROOT, "index.html"), "utf8");

function loadSetWorkspaceCtaHref(): (hostname: string, origin: string) => string {
  const fn = /function setWorkspaceCtaHref\(\) \{([\s\S]*?)\n  \}/.exec(html);
  assert.ok(fn, "setWorkspaceCtaHref not found in index.html");
  const body = fn[1];

  const links: Record<string, { href: string }> = {
    workspaceCtaNav: { href: "" },
    workspaceCtaHero: { href: "" },
  };
  const fakeDocument = {
    getElementById: (id: string) => links[id] ?? null,
  };

  return (hostname: string, origin: string) => {
    const fakeWindow = { location: { hostname, origin } };
    new Function("window", "document", body)(fakeWindow, fakeDocument);
    return links.workspaceCtaNav.href;
  };
}

const run = loadSetWorkspaceCtaHref();

test("on the new CavScope domain, the CTA stays same-origin at /signin", () => {
  assert.equal(run("cavscope.28footsystems.com", "https://cavscope.28footsystems.com"), "https://cavscope.28footsystems.com/signin");
});

test("the www form of the new domain is treated the same as the apex", () => {
  assert.equal(run("www.cavscope.28footsystems.com", "https://www.cavscope.28footsystems.com"), "https://www.cavscope.28footsystems.com/signin");
});

test("on every legacy host, the CTA still hops to the app.muster.partners origin", () => {
  for (const [hostname, origin] of [
    ["muster.partners", "https://muster.partners"],
    ["www.muster.partners", "https://www.muster.partners"],
    ["muster.28footsystems.com", "https://muster.28footsystems.com"],
  ] as const) {
    assert.equal(run(hostname, origin), "https://app.muster.partners/");
  }
});

test("both workspace CTAs are updated, not just one", () => {
  const bothIds = /for \(const id of \['workspaceCtaNav', 'workspaceCtaHero'\]\)/;
  assert.match(html, bothIds);
});
