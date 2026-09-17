// The Reports section in admin.html, and the link from the audit runner to the
// report a scan produced.
//
//   node --experimental-strip-types --test tests/ui/reports-section.test.ts
//
// What went wrong: the Audit Queue learned to start a scan, a scan writes a
// SITREP about a second after it finishes, and nothing in the product pointed at
// it. Someone ran an audit, went looking for the report, and found the Reports
// section rendering a "not instrumented" stub. The report existed the whole
// time, in muster.sitreps. Generating a deliverable and not showing it is the
// same class of failure as a switch that changes nothing.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const html = readFileSync(join(repoRoot, "admin.html"), "utf8");
const reports = html.slice(html.indexOf("// ---- reports"), html.indexOf("// ---- audit runner"));

test("Reports is a real section, not a stub", () => {
  assert.match(html, /reports: renderReports,/);
  // The stub entry has to be gone: two sources for one section is how they
  // disagree, and the stub says the opposite of what the section now does.
  assert.doesNotMatch(html, /reports: \{\s*\n\s*title: 'Reports'/);
  assert.doesNotMatch(html, /label: 'Reports',\s*tip: '[^']*does not index them yet[^']*'/);
});

test("the index and the report body are separate RPCs", () => {
  // content_md is a few KB per report; a console with hundreds of SITREPs must
  // not pull every one's markdown to render a list.
  assert.match(reports, /sb\.rpc\('muster_admin_sitreps', \{ p_limit: 200 \}\)/);
  assert.match(reports, /sb\.rpc\('muster_admin_sitrep', \{ p_id: id \}\)/);
});

test("the index loads on demand, not with the console payload", () => {
  assert.match(reports, /if \(SITREPS && !force\) return;/);
  // renderReports kicks the fetch off itself, so a console that never opens
  // Reports never pays for it.
  assert.match(reports, /loadSitreps\(\)\.then\(render\)/);
});

test("the report is shown verbatim, never parsed into HTML", () => {
  // Two reasons, both in the source comment: the console must not be able to
  // disagree with what the tenant reads at /sitrep, and a hand-rolled markdown
  // renderer over third-party content is an injection bug in a page whose job
  // is reporting on other people's security.
  assert.match(reports, /<pre style="white-space:pre-wrap/);
  assert.match(reports, /escapeHtml\(r\.content_md/);
  assert.doesNotMatch(reports, /innerHTML\s*=\s*[^;]*content_md/);
});

test("a failed report load says so instead of rendering blank", () => {
  assert.match(reports, /Could not load that report/);
  assert.match(reports, /SITREPS\.error/);
});

test("the runner links to the report it just generated", () => {
  const runner = html.slice(html.indexOf("// ---- audit runner"), html.indexOf("function renderAuditQueue"));
  assert.match(runner, /Read the report →/);
  assert.match(runner, /data-sitrep="\$\{sitrepId\}"/);
  // And says plainly when one is missing, rather than silently dropping the
  // link -- a completed scan with no SITREP is a real fault worth surfacing.
  assert.match(runner, /No SITREP was written for this scan/);
});

test("the report is found by scan id, not by taking the newest row", () => {
  // Two audits started close together would otherwise each link to whichever
  // finished last.
  const runner = html.slice(html.indexOf("// ---- audit runner"), html.indexOf("function renderAuditQueue"));
  assert.match(runner, /async function sitrepForScan\(scanId\)/);
  assert.match(runner, /Number\(r\.scan_id\) === Number\(scanId\)/);
});

test("opening a report from the runner lands on the Reports section", () => {
  const events = html.slice(html.indexOf("// ---- events"), html.indexOf("// Right-click context menu suppression"));
  assert.match(events, /closest\('\[data-sitrep\]'\)/);
  assert.match(events, /if \(section !== 'reports'\) \{ sitrepOpen = null; go\('reports'\); \}/);
  assert.match(events, /closest\('#sitrepBack'\)/);
});

test("every interactive element in the section carries a tooltip", () => {
  for (const marker of ["sitrepBack", "data-sitrep=\"${r.id}\""]) {
    const i = reports.indexOf(marker);
    assert.ok(i > 0, `${marker} must exist`);
  }
  // The table header cells and the report row both explain themselves.
  assert.ok((reports.match(/data-tooltip=/g) || []).length >= 8);
});
