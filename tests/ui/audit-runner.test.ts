// The audit runner in admin.html: the one write action on a read-only console.
//
//   node --experimental-strip-types --test tests/ui/audit-runner.test.ts
//
// admin.html was read-only until 2026-09-17 -- every figure on it came from one
// read, muster_admin_console(), and app.html's superadmin view owned the actions.
// Running an audit is now here too, because this is the page you are already on
// when you notice a site needs one.
//
// Two things this guards, both of which have bitten this codebase before:
//
//   1. A scan is QUEUED when the RPC returns, not finished. do_request_scan fires
//      the engine through net.http_post, which pg_net hands to a background
//      worker before returning. Reading the result immediately shows a queued
//      scan with no findings -- which is what "the audit did not populate" turned
//      out to be in app.html. The runner must poll to a terminal status.
//   2. The panel re-renders on every status update, because render() replaces the
//      whole page. A field held only in the DOM would be blanked mid-scan, with
//      the URL you typed still being scanned.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const html = readFileSync(join(repoRoot, "admin.html"), "utf8");

const runner = html.slice(html.indexOf("// ---- audit runner"), html.indexOf("function renderAuditQueue"));

test("the runner calls the two gated RPCs that already exist, and adds none", () => {
  assert.match(runner, /sb\.rpc\('muster_admin_run_url', \{ p_url: url \}\)/);
  assert.match(runner, /sb\.rpc\('muster_request_scan', \{ p_website_id: websiteId \}\)/);
  // Polling reads one website's scans rather than re-reading the whole console
  // payload on a loop.
  assert.match(runner, /sb\.rpc\('muster_scans', \{ p_website_id: websiteId, p_limit: 5 \}\)/);
});

test("both actions wait for a terminal status instead of reporting on the queue", () => {
  // The bug this prevents: reporting success the moment the RPC returns.
  assert.match(runner, /async function awaitScan\(websiteId, scanId\)/);
  assert.match(runner, /hit\.status === 'complete' \|\| hit\.status === 'failed'/);
  // Both paths must go through it.
  const urlScan = runner.slice(runner.indexOf("async function runUrlScan"), runner.indexOf("async function runSiteScan"));
  const siteScan = runner.slice(runner.indexOf("async function runSiteScan"));
  assert.ok(urlScan.includes("await awaitScan("), "the URL scan must await the engine");
  assert.ok(siteScan.includes("await awaitScan("), "the site re-audit must await the engine");
  // And the wait has to end, so a hung engine does not spin forever.
  assert.match(runner, /RUN_POLL_TRIES = \d+/);
  assert.match(runner, /return \{ status: 'timeout' \}/);
});

test("a failed scan is never reported as a completed one", () => {
  // A failed scan produces no findings, so the site keeps its previous score.
  // Saying "complete" there would claim a check that never ran.
  assert.match(runner, /result\.status === 'failed'/);
  assert.match(runner, /could not complete the scan/);
  assert.match(runner, /previous score still stands/);
});

test("the form fields survive a re-render, because the panel re-renders mid-scan", () => {
  assert.match(runner, /const run = \{[^}]*url: '',[^}]*siteId: ''/s);
  assert.match(runner, /value="\$\{escapeHtml\(run\.url\)\}"/);
  assert.match(runner, /String\(w\.id\) === String\(run\.siteId\) \? ' selected' : ''/);
  // And the scan must read state, not the node it re-rendered away.
  assert.match(runner, /const url = \(run\.url \|\| ''\)\.trim\(\)/);
  assert.match(runner, /const websiteId = run\.siteId \? Number\(run\.siteId\) : null/);
});

test("the selected site cannot drift from what the dropdown shows", () => {
  // A browser shows the first option as selected whether or not anything set it.
  assert.match(runner, /if \(!sites\.some\(\(w\) => String\(w\.id\) === String\(run\.siteId\)\)\)/);
  assert.match(runner, /run\.siteId = sites\.length \? String\(sites\[0\]\.id\) : ''/);
});

test("re-auditing a real customer site asks first; the sandbox scan does not", () => {
  const siteScan = runner.slice(runner.indexOf("async function runSiteScan"));
  assert.match(siteScan, /window\.confirm\(/);
  assert.match(siteScan, /risk register/);
  // Wrapped across template-literal lines in the source, so match the words, not
  // the layout: the prompt has to say the customer's score can move.
  assert.ok(/posture/.test(siteScan) && /score may change/.test(siteScan),
    "the prompt must warn that the posture score can change");
  // The ad-hoc scanner targets the internal sandbox org, which is nobody's data,
  // so it deliberately has no confirm.
  const urlScan = runner.slice(runner.indexOf("async function runUrlScan"), runner.indexOf("async function runSiteScan"));
  assert.ok(!urlScan.includes("window.confirm"), "the sandbox URL scan should not prompt");
});

test("a 42501 is explained by cause, not reported as a generic denial", () => {
  // The two causes are genuinely different and send you to different places:
  // not a super admin, or the flag gating the capability is off.
  assert.match(runner, /manual scans are disabled/i);
  assert.match(runner, /manual_scans/);
  assert.match(runner, /admin_url_scanner/);
  assert.match(runner, /does not grant anything on/);
});

test("the runner states plainly that it is a form, not a permission check", () => {
  assert.match(runner, /Nothing below is a permission check; it is a form\./);
  assert.match(runner, /muster\.is_super_admin\(\) \/ muster\.can_write_org\(\)/);
});

test("the buttons are matched by delegation, since the node is replaced mid-scan", () => {
  const events = html.slice(html.indexOf("// ---- events"), html.indexOf("// Right-click context menu suppression"));
  assert.match(events, /closest\('#runUrlBtn'\)/);
  assert.match(events, /closest\('#runSiteBtn'\)/);
  // Guarded so a second click during a scan cannot start another.
  assert.match(events, /if \(!run\.busy\) runUrlScan\(\)/);
  assert.match(events, /if \(!run\.busy\) runSiteScan\(\)/);
});

test("typing in the URL field does not re-render, which would move the caret", () => {
  const events = html.slice(html.indexOf("// ---- events"), html.indexOf("// Right-click context menu suppression"));
  const line = events.split("\n").find((l) => l.includes("run.url = e.target.value"));
  assert.ok(line, "the URL field must record what was typed");
  assert.ok(!line!.includes("render()"), "recording a keystroke must not re-render the page");
});

test("the runner is reachable from the Audit Queue section", () => {
  const section = html.slice(html.indexOf("function renderAuditQueue"), html.indexOf("function renderWebsiteAssurance"));
  assert.match(section, /panel\('Run an audit'/);
  assert.match(section, /auditRunner\(\)/);
});

test("every interactive element in the runner carries a tooltip", () => {
  // The standing rule in CLAUDE.md. These are the first form controls this page
  // has ever had, so there is no prior example on it to copy.
  for (const id of ["runUrl", "runUrlBtn", "runSite", "runSiteBtn"]) {
    const i = runner.indexOf(`id="${id}"`);
    assert.ok(i > 0, `${id} must exist`);
    // The tooltip is on the same tag: look from the id to the end of that tag.
    const tag = runner.slice(runner.lastIndexOf("<", i), runner.indexOf(">", runner.indexOf("data-tooltip", i)) + 1);
    assert.ok(tag.includes("data-tooltip"), `${id} needs a data-tooltip`);
  }
});
