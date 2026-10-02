// A live workspace must never show the sample workspace's content as its own.
//
//   node --experimental-strip-types --test tests/ui/live-sweep.test.ts
//
// On 2026-09-28 a sweep rendered every workspace view twice in Chromium, once in
// demo mode and once as a live tenant fed that tenant's real payloads
// (tools/live-sweep/), and diffed the two. It found:
//
//   - both workspace reports telling every tenant their report "was generated
//     before the report template existed": the overview's latest_sitrep is a
//     stub and nothing fetched the rest
//   - the Accessibility "Health Index" being the security posture relabelled,
//     every rule with no finding scored 10/10, and a summary sentence about the
//     sample's fictional keyboard trap
//   - "Within Tolerance", "Formally Approved", the Governance tolerance figures,
//     "Fleet Conformance 86%" and "Deliverables 12": fixed text nothing wrote
//   - scans listed as "Effective" control tests
//   - six record forms that updated page state, toasted success and saved
//     nothing, and a "Verify" button that only toasted "Artifact reviewed."
//   - hidden="" doing nothing on any element whose class sets display
//   - switching to the demo leaving the tenant's real SITREP, laws and team on
//     a screen labelled sample data
//
// Chromium is not available to the offline suite, so this file pins what can be
// pinned from the source and runs the pure pieces. Rerun tools/live-sweep/
// after any change to a workspace view.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const app = readFileSync(join(repoRoot, "app.html"), "utf8");
const scripts = [...app.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)].map((m) => m[1]).join("\n");

// --- the rule that found half of these ---------------------------------------

// Headings that are labels, not data. Anything else with an id and visible text
// inside a workspace view is there to be filled, and must be written by a script.
const FIXED_HEADINGS = new Set(["lblAioPillarsHead", "lblPlainReportTitle", "lblBoardReportTitle"]);

test("every id-bearing text in a workspace view is written by some script", () => {
  const start = app.indexOf('<section id="subclients"');
  const end = app.indexOf('<section id="teamSettings"');
  assert.ok(start > 0 && end > start);
  const views = app.slice(start, end);
  const unwritten: string[] = [];
  for (const m of views.matchAll(/<(\w+)([^>]*?)\bid="([^"]+)"([^>]*)>\s*([^<]{1,80})</g)) {
    const [, , , id, , text] = m;
    if (!text.trim() || FIXED_HEADINGS.has(id)) continue;
    if (!new RegExp(`['"\`]${id.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}['"\`]`).test(scripts)) unwritten.push(`${id}: ${text.trim().slice(0, 40)}`);
  }
  assert.deepEqual(unwritten, [], "fixed sample text a live tenant would read as their own");
});

test("hidden wins over any class that sets display", () => {
  assert.match(app, /\[hidden\] \{ display: none !important; \}/);
});

// --- the report is loaded, and a stub is never mistaken for an old report ----

test("the workspace loads the full latest SITREP, and says so when it cannot", () => {
  assert.match(app, /this\.rpc\('cavscope_latest_sitrep', \{ p_website_id: this\.website\.id \}\)/);
  assert.match(app, /else this\.overview\.latest_sitrep\.load_failed = true;/);
  const rr = app.slice(app.indexOf("function renderReport(profile, sitrep, brand, opts) {"));
  assert.ok(rr.indexOf("if (!sitrep.sections)") < rr.indexOf("generated before the report template existed"),
    "a report whose sections did not load must not be described as an old report");
  assert.match(app, /\$\{sitrep && sitrep\.content_md \? `<button/);
});

// --- accessibility is scored like AIO, never from posture --------------------

const liveA11y = (() => {
  const src = app.slice(app.indexOf("      a11yChecks: ["), app.indexOf("      aioChecks: ["));
  // deno-lint-ignore no-explicit-any
  return (ruleStatus: unknown) => new Function("ruleStatus", `return ({ ruleStatus, ${src} });`)(ruleStatus) as any;
})();
const A11Y = ["A11Y-001", "A11Y-002", "A11Y-003", "A11Y-004", "A11Y-005", "A11Y-006", "A11Y-007"];
const allActive = A11Y.map((rule_id) => ({ rule_id, active: true }));
const scan = { id: 126, status: "complete", engine_version: "http-native-1.15.0" };

test("a check with no finding passes only if its rule could have run", () => {
  const L = liveA11y(allActive.map((r) => (r.rule_id === "A11Y-004" ? { ...r, active: false } : r)));
  const out = L.buildAccessibility({ recent_scans: [scan], findings: [{ rule_id: "A11Y-003", detail: "3 images without alt" }] });
  const state = Object.fromEntries(out.checks.map((c: { rule: string; state: string }) => [c.rule, c.state]));
  assert.equal(state["A11Y-003"], "fail");
  assert.equal(state["A11Y-004"], "na", "an inactive rule is not assessed, never passed");
  assert.equal(state["A11Y-001"], "pass");
  assert.equal(out.overallScore, Math.round((100 * 5) / 6), "the index excludes what was not assessed");
  assert.equal(out.pillars.at(-1).score, null, "browser-only areas are not assessed, never 0/10");
  assert.match(out.summary, /5 of 6 automated checks pass on scan #126/);
  assert.match(out.summary, /not a WCAG conformance rating/);
});

test("an unread homepage or a missing scan assesses nothing", () => {
  const unread = liveA11y(allActive).buildAccessibility({ recent_scans: [scan], findings: [{ rule_id: "AVAIL-003", detail: "403" }] });
  assert.equal(unread.overallScore, null);
  assert.ok(unread.checks.every((c: { state: string }) => c.state === "na"));
  const none = liveA11y(allActive).buildAccessibility({ recent_scans: [], findings: [] });
  assert.equal(none.overallScore, null);
  assert.match(none.summary, /No completed scan yet/);
  const noStatus = liveA11y(null).buildAccessibility({ recent_scans: [scan], findings: [] });
  assert.ok(noStatus.checks.every((c: { state: string }) => c.state === "na"), "unknown rule state is not a pass");
});

test("the accessibility index is never the security posture, and the sample's summary never reaches live", () => {
  assert.doesNotMatch(app, /accessibility\.overallScore = posture/);
  assert.match(app, /Object\.assign\(base\.accessibility, this\.buildAccessibility\(ov\)\)/);
  assert.match(app, /liveCopy\('wcagScoreSummary', live \? a11y\.summary : null\)/);
  assert.match(app, /\[\.\.\.this\.aioChecks\.map\(c => c\.rule\), \.\.\.this\.a11yChecks\.map\(\(\[r\]\) => r\)\]/,
    "rule status must be fetched for the accessibility rules too, or every check reads not assessed");
});

test("engine severity maps onto P0-P4 rather than sending everything below high to P1 Critical", () => {
  assert.match(app, /\(\{ critical: 'P0', high: 'P1', medium: 'P2', low: 'P3', info: 'P4' \}\)\[f\.severity\] \|\| 'P4'/);
});

// --- governance, appetite, clients, assurance ---------------------------------

test("nothing in a live workspace claims an approval the schema never records", () => {
  const build = app.slice(app.indexOf("      buildState(o, ov) {"), app.indexOf("      a11yChecks: ["));
  assert.doesNotMatch(build, /'Formally Approved'/);
  assert.match(build, /status: appetite\.updated_at \? `Last saved/);
  const gov = app.slice(app.indexOf("    function renderGovernance() {"));
  for (const id of ["govCritTol", "govHighTol", "govCadence", "govAppetiteStatus"]) assert.match(gov.slice(0, 1600), new RegExp(`'${id}'`));
});

test("the Overview's tolerance verdict is computed from the register against the saved appetite", () => {
  const fn = app.slice(app.indexOf("    function renderOverviewAppetite() {"), app.indexOf("    function renderOverview() {"));
  assert.match(fn, /r\.status === 'open' \|\| r\.status === 'in_progress'/);
  assert.match(fn, /crit <= critTol && high <= highTol/);
  assert.match(fn, /'Outside Tolerance'/);
  assert.match(fn, /'Not set'/);
});

test("an unscanned client site has no score rather than zero, and the fleet tiles are computed or say they are not", () => {
  assert.match(app, /scope: 'HTTP-native scan', score: w\.posture_score \?\? null,/);
  assert.match(app, /c\.score == null \? 'Not scanned'/);
  assert.match(app, /liveCopy\('subclientDeliverables', live \? '—' : null\)/);
});

test("a completed scan is never an 'Effective' control test", () => {
  assert.doesNotMatch(app, /result: s\.status === 'complete' \? 'Effective'/);
  assert.match(app, /result: s\.status === 'complete' \? 'Scan completed'/);
});

// --- nothing pretends to save --------------------------------------------------

test("record forms with no backend are hidden and refused in a live workspace", () => {
  const m = app.match(/const DEMO_ONLY_MODALS = \[([^\]]+)\]/);
  assert.ok(m);
  const types = m![1].split(",").map((t) => t.trim().replace(/'/g, ""));
  for (const t of ["risk", "control", "evidence", "exception", "remediation", "test"]) assert.ok(types.includes(t), `${t} would fake a save`);
  // Every modal type the live form handler does not route to an RPC is in the list.
  const liveRouted = [...app.slice(app.indexOf("    handleFormSubmit = function (e) {")).slice(0, 1800).matchAll(/currentModalType === '([a-z_]+)'/g)].map((x) => x[1]);
  // A modal the live openModal wrapper intercepts is never opened in a live workspace, so it
  // cannot fake a save: create_tenant is redirected to the real client-organization path.
  liveRouted.push(...[...app.matchAll(/isLiveWorkspace\(\) && type === '([a-z_]+)'/g)].map((x) => x[1]));
  const all = [...new Set([...app.matchAll(/currentModalType === '([a-z_]+)'/g)].map((x) => x[1]))];
  for (const t of all) assert.ok(liveRouted.includes(t) || types.includes(t), `modal '${t}' neither saves live nor is refused`);
  assert.match(app, /if \(isLiveWorkspace\(\) && DEMO_ONLY_MODALS\.includes\(type\)\)/);
  assert.match(app, /if \(typeof syncDemoOnlyControls === 'function'\) syncDemoOnlyControls\(\);/);
});

test("toast-only buttons are sample-only, and engine captures are not called verified", () => {
  for (const m of app.matchAll(/onclick="showToast\([^"]*\)"/g)) {
    const before = app.slice(Math.max(0, m.index! - 200), m.index!);
    assert.match(before, /isLiveWorkspace\(\) \? '' : `<button/, `a toast-only button is live: ${m[0]}`);
  }
  assert.doesNotMatch(app, /System-verified/);
});

// --- switching to the demo puts the demo back -----------------------------------

test("the demo is restored whole, and sample figures are labelled as sample", () => {
  const rd = app.slice(app.indexOf("      restoreDemo() {"));
  assert.match(rd.slice(0, 1200), /document\.querySelectorAll\('\.live-panel'\)\.forEach\(el => el\.remove\(\)\)/);
  assert.match(app, /: 'Sample data';/);
  assert.match(app, /const sampleCopy = Object\.create\(null\);/);
});

test("the default brand is CavScope's, in the mark as well as the name", () => {
  assert.doesNotMatch(app, />MU</);
  assert.match(app, /mark: "CS"/);
  assert.match(app, /overviewEyebrow\.textContent = `Executive Line of Sight — \$\{b\.name\}`/);
});
