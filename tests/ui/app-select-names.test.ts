// Every <select> in the workspace needs an accessible name, and the explainer banners must not skip
// heading levels. Found 2026-10-10 by rendering /app signed in (tools/site-axe/app.mjs): six selects
// (risk filters, scan frequency, invite role, API key kind and scopes) had no name at all, which axe
// rates critical, and two banner h4s were the first heading in their view.
//
//   node --experimental-strip-types --test tests/ui/app-select-names.test.ts

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const html = readFileSync(join(dirname(fileURLToPath(import.meta.url)), "..", "..", "app.html"), "utf8");

test("the selects that had no accessible name now carry one", () => {
  for (const frag of [
    'id="riskSeverityFilter" aria-label="Filter by severity"',
    'id="riskStatusFilter" aria-label="Filter by status"',
    'aria-label="Scan frequency" data-act="scan-cadence"',
    '<select name="role" aria-label="Role">',
    '<select name="kind" aria-label="Kind" ',
    '<select name="scopes" aria-label="Scopes" ',
  ]) assert.ok(html.includes(frag), `missing: ${frag}`);
});

test("explainer banners use h3, so they do not skip a level", () => {
  assert.doesNotMatch(html, /<h4[^>]*>(?:\s*<span>♿<\/span>)? ?(?:Technical Conformance|⚖ Not a Certification)/);
  assert.match(html, /\.simple-explainer-banner h3 \{/);
  assert.doesNotMatch(html, /\.simple-explainer-banner h4 \{/);
});
