// AI Readiness section of the Super Admin Console (admin.html).
//
//   node --experimental-strip-types --test tests/ui/console-ai-readiness.test.ts
//
// The section was a "not instrumented" stub claiming no AI-readiness assessment, scoring rules or
// findings category exist. Nine engine rules have driven the workspace's AIO view since
// 2026-09-23. The console now reads them for every site, judged the way the workspace judges them.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const html = readFileSync(join(root, "admin.html"), "utf8");
const app = readFileSync(join(root, "app.html"), "utf8");
const m1 = readFileSync(join(root, "supabase/migrations/20261010202353_admin_aio_overview.sql"), "utf8");
const m2 = readFileSync(join(root, "supabase/migrations/20261010202426_admin_aio_overview_organization_id.sql"), "utf8");

test("the section is no longer a stub and says nothing false about missing assessments", () => {
  assert.match(html, /'ai-readiness': renderAiReadiness/);
  assert.doesNotMatch(html, /no readiness assessment tables exist/);
  assert.doesNotMatch(html, /There is no AI-readiness assessment table/);
  const nav = html.slice(html.indexOf("id: 'ai-readiness'"), html.indexOf("id: 'ai-readiness'") + 400);
  assert.doesNotMatch(nav.split("\n")[0], /stub: true/);
});

test("it reads the console's own RPC, loaded with the other side reads", () => {
  assert.match(html, /aio: \['cavscope_admin_aio_overview'\]/);
});

test("the nine checks, their release floors and the GOV-004 rule match the workspace's AIO view", () => {
  const workspace = [...app.slice(app.indexOf("aioChecks: ["), app.indexOf("aioPillars: [")).matchAll(/rule: '([A-Z0-9-]+)'(?:[^}]*floor: '([\d.]+)')?/g)]
    .map((m) => `${m[1]}:${m[2] || ""}`);
  const sql = [...m1.matchAll(/\((\d), '([A-Z0-9-]+)',\s+'\w+',\s+(?:'([\d.]+)'|null)/g)].map((m) => `${m[2]}:${m[3] || ""}`);
  assert.equal(workspace.length, 9);
  assert.deepEqual(sql, workspace);
});

test("a check that could not run is never a pass", () => {
  assert.match(m1, /when s\.scan_id is null then 'na'/);
  assert.match(m1, /when s\.unread then 'na'/);
  assert.match(m1, /when not coalesce\(r\.active, false\) then 'na'/);
  assert.match(m1, /'AVAIL-001', 'AVAIL-003', 'AVAIL-004'/);
  assert.match(m1, /revoke all on function public\.cavscope_admin_aio_overview\(\) from public, anon/);
});

test("the page says it measures readiness, not citation, and never scores citability", () => {
  assert.match(html, /not whether any assistant cites the site/);
  assert.match(html, /citability is never scored/);
});

test("the organization id part edits once", () => {
  assert.match(m2, /expected exactly 1 match/);
  assert.match(m2, /organization_id/);
});
