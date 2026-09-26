// muster-alert-dispatch/index.ts imports "jsr:@supabase/functions-js/..."
// and calls Deno.serve() at module scope, so it cannot be imported into a
// plain Node test the way muster-resend-webhook's core.ts can (see
// tests/email/resend-webhook.test.ts) -- there is no pure half split out of
// it yet. This pins the CTA-href contract against the shipped source text
// instead, the same technique tests/migrations/doubled-backslash-regex.test.ts
// and cavscope-branding.test.ts already use for SQL that can't be imported
// either.
//
//   node --experimental-strip-types --test tests/email/alert-dispatch-cta.test.ts
//
// Until 2026-09-26 every category's CTA button pointed at the bare
// workspace root (APP_URL), regardless of what the email was actually
// about -- a SITREP-ready email's "View your SITREP" button did not open
// the SITREP it announced. ctaHref is now a function of the outbox row so
// a category with a real destination can use it: sitrep_ready already had
// one (sitrep.html's ?sitrep_id= param), risk_opened gained one today
// (app.html's #risks view, opened by loadWorkspace()'s new fragment
// handling). workspace_created and website_added deliberately keep the
// bare root -- app.html has no per-org landing or multi-website switcher
// to link to yet -- so this only pins the two that changed, plus the type
// signature and call site for all four.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const src = readFileSync(
  join(repoRoot, "supabase", "functions", "muster-alert-dispatch", "index.ts"),
  "utf8",
);

test("CATEGORY_META.ctaHref is typed as a function of the row, not a static string", () => {
  assert.match(src, /ctaHref: \(row: OutboxRow\) => string/);
});

test("risk_opened's CTA links to the Risk Register view, not the bare workspace root", () => {
  assert.match(src, /ctaHref: \(\) => `\$\{APP_URL\}#risks`/);
});

test("sitrep_ready's CTA links to the specific SITREP by id", () => {
  assert.match(src, /ctaHref: \(row\) => `\$\{SITREP_URL\}\?sitrep_id=\$\{row\.entity_id\}`/);
});

test("workspace_created and website_added still resolve to the bare app URL (no switcher to link into yet)", () => {
  const workspaceCreated = src.slice(src.indexOf("workspace_created:"), src.indexOf("website_added:"));
  assert.match(workspaceCreated, /ctaHref: \(\) => APP_URL/);
  const websiteAdded = src.slice(src.indexOf("website_added:"));
  assert.match(websiteAdded, /ctaHref: \(\) => APP_URL/);
});

test("the render call site invokes ctaHref as a function against the current row", () => {
  assert.match(src, /href="\$\{esc\(meta\.ctaHref\(row\)\)\}"/);
});
