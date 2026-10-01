// The Overview's four tiles must show a live workspace its own numbers.
//
//   node --experimental-strip-types --test tests/ui/overview-kpis.test.ts
//
// Until 2026-09-28 the tiles were fixed HTML. A signed-in tenant saw the sample's
// posture 82, "1 active critical risk", control coverage 80% ("4 of 5 mapped"),
// evidence readiness 75% ("3 approved artifacts") and remediation 65% on the
// first screen of their workspace, each stamped "As of" the current minute, so
// the fiction read as fresh. Nothing on the page ever replaced them, and no test
// noticed, because every test read the source for markup rather than running
// what a signed-in tenant runs.
//
// This file runs the real renderOverviewKpis() and liveScoreExplainer(), lifted
// out of app.html, against a small fake DOM built from the tiles' own markup.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const app = readFileSync(join(repoRoot, "app.html"), "utf8");

const gridOpen = '<div class="grid-4" id="overviewKpis">';
const gridHtml = app.slice(app.indexOf(gridOpen) + gridOpen.length, app.indexOf("<!-- Priority Risks"));
const fnSrc = app.slice(app.indexOf("    const POSTURE_WEIGHTS"), app.indexOf("    function renderOverview() {"));
const escAt = app.indexOf("function escapeHtml(");
const escSrc = app.slice(escAt, app.indexOf("\n    }\n", escAt) + 6);

// --- a fake DOM just large enough for the tiles ------------------------------

type El = {
  id?: string; textContent: string; className: string; hidden: boolean;
  style: Record<string, string>; parentElement: { hidden: boolean };
  attrs: Record<string, string>;
  setAttribute(k: string, v: string): void; getAttribute(k: string): string | undefined;
  closest(sel: string): Card | null;
};
type Card = { attrs: Record<string, string>; asof: El | null; setAttribute(k: string, v: string): void; getAttribute(k: string): string | undefined; querySelector(sel: string): El | null };

function makeDom() {
  let html = "";
  let byId = new Map<string, El>();
  let asofs: El[] = [];
  const el = (o: Partial<El>): El => {
    const e: El = {
      textContent: "", className: "", hidden: false, style: {}, parentElement: { hidden: false }, attrs: {},
      setAttribute(k, v) { this.attrs[k] = v; }, getAttribute(k) { return this.attrs[k]; }, closest: () => null, ...o,
    } as El;
    return e;
  };
  const parse = () => {
    byId = new Map(); asofs = [];
    const chunks = html.split('<div class="card metric-card"').slice(1);
    for (const chunk of chunks) {
      const tip = (chunk.match(/^[^>]*data-tooltip="([^"]*)"/) || [])[1] || "";
      const card: Card = {
        attrs: { "data-tooltip": tip }, asof: null,
        setAttribute(k, v) { this.attrs[k] = v; }, getAttribute(k) { return this.attrs[k]; },
        querySelector(sel) { return sel === "[data-asof]" ? this.asof : null; },
      };
      if (/data-asof/.test(chunk)) { card.asof = el({}); asofs.push(card.asof); }
      for (const m of chunk.matchAll(/<(\w+)([^>]*)\bid="([^"]+)"([^>]*)>([^<]*)/g)) {
        const attrs = m[2] + m[4];
        const e = el({ id: m[3], textContent: m[5].trim(), className: (attrs.match(/class="([^"]*)"/) || [])[1] || "" });
        e.closest = () => card;
        byId.set(m[3], e);
      }
    }
  };
  const grid = {
    get innerHTML() { return html; },
    set innerHTML(v: string) { html = v; parse(); },
    querySelectorAll(sel: string) { return sel === "[data-asof]" ? asofs : []; },
  };
  const document = { getElementById: (id: string) => (id === "overviewKpis" ? grid : byId.get(id) || null) };
  grid.innerHTML = gridHtml;
  return { document, byId: () => byId, asofs: () => asofs };
}

function run(live: boolean, Live: Record<string, unknown>) {
  const dom = makeDom();
  // deno-lint-ignore no-explicit-any
  const api = new Function("document", "Live", "isLiveWorkspace",
    `${escSrc}\n${fnSrc}\nreturn { renderOverviewKpis, liveScoreExplainer };`)(dom.document, Live, () => live) as any;
  api.renderOverviewKpis();
  const text = (id: string) => (dom.byId().get(id) || { textContent: "" }).textContent;
  const cardTip = (id: string) => dom.byId().get(id)!.closest(".metric-card")!.getAttribute("data-tooltip");
  return { api, text, cardTip, dom };
}

const SAMPLE_LITERALS = ["1 active critical risk", "Target: 95%+", "4 of 5 mapped", "SOC 2, GDPR, WCAG",
  "3 approved artifacts", "1 in review", "0 overdue actions", "4 treatments active", "80+ Good"];

// Shaped like cavscope_website_overview and cavscope_risks for a real tenant site.
const LIVE = {
  overview: {
    posture_score: 61, posture_band: "amber", open_by_severity: { critical: 1, high: 1, medium: 1, low: 0, info: 2 },
    // The count lives on the scan summary. The SITREP's evidence_index lists
    // only what the report cites (2 of 18 on org 3's real scan 126), so reading
    // it undercounted -- the first version of this tile did exactly that.
    latest_scan: { status: "complete", finished_at: "2026-09-28T07:29:40Z", summary: { evidence: 23 } },
    latest_sitrep: { generated_at: "2026-09-28T07:30:06Z", sections: {
      report: { controls: { met: 57, total: 94, rate: 61, partial: 32, not_met: 5, not_assessed: 0, as_of: "2026-09-28T07:30:06Z" } },
      evidence_index: [{ evidence_id: 1 }, { evidence_id: 2 }] } },
  },
  risks: [
    { status: "open", target_date: "2000-01-01" }, { status: "open", target_date: "2999-01-01" },
    { status: "in_progress", target_date: "2000-01-02" }, { status: "mitigated", target_date: "2000-01-03" },
  ],
};

test("demo mode keeps the sample figures and labels them as sample data, never as 'As of' now", () => {
  const { text, dom } = run(false, {});
  assert.equal(text("kpiPostureScore"), "82");
  assert.ok(dom.asofs().length === 4 && dom.asofs().every((e) => e.textContent === "Sample data"));
});

test("a live workspace sees its own posture, band and critical count", () => {
  const { text, cardTip } = run(true, LIVE);
  assert.equal(text("kpiPostureScore"), "61");
  assert.equal(text("kpiPostureTier"), "Amber");
  assert.equal(text("kpiCriticalCount"), "1 open critical finding");
  assert.equal(text("kpiPostureTarget"), "Green at 85+");
  assert.match(cardTip("kpiPostureScore")!, /25 for each open critical finding, 10 per high, 4 per medium and 1 per low/);
});

test("control coverage is the latest report's own figures", () => {
  const { text } = run(true, LIVE);
  assert.equal(text("kpiControlCoverage"), "61");
  assert.equal(text("kpiControlsMet"), "57 of 94 derived controls met");
  assert.equal(text("kpiControlsDetail"), "32 partial, 5 not met");
});

test("evidence is a count, never a readiness percentage or an approval", () => {
  const { text, cardTip } = run(true, LIVE);
  assert.equal(text("kpiEvidenceLabel"), "Evidence Captured");
  assert.equal(text("kpiEvidenceReadiness"), "23");
  assert.equal(text("kpiEvidenceDenom"), "items");
  assert.equal(text("kpiEvidenceReview"), "Auditor review not tracked");
  assert.match(cardTip("kpiEvidenceReadiness")!, /does not track whether an auditor has reviewed/);
});

test("remediation is the register's mitigated share, with overdue counted from target dates", () => {
  const { text } = run(true, LIVE);
  assert.equal(text("kpiRemediationProgress"), "25");
  assert.equal(text("kpiRemediationOverdue"), "2 overdue risks");
  assert.equal(text("kpiRemediationActive"), "1 of 4 mitigated, 1 in progress");
});

test("no live tile ever shows a sample figure, and a workspace with nothing says so", () => {
  for (const L of [LIVE, { overview: { posture_score: null, latest_scan: null, latest_sitrep: null }, risks: [] }]) {
    const { dom } = run(true, L);
    const shown = [...dom.byId().values()].map((e) => e.textContent).join(" | ");
    for (const lit of SAMPLE_LITERALS) assert.ok(!shown.includes(lit), `live tile shows the sample's "${lit}"`);
  }
  const { text } = run(true, { overview: { posture_score: null, latest_scan: null, latest_sitrep: null }, risks: [] });
  for (const id of ["kpiPostureScore", "kpiControlCoverage", "kpiEvidenceReadiness", "kpiRemediationProgress"]) {
    assert.equal(text(id), "—", `${id} invents a number for an empty workspace`);
  }
  assert.equal(text("kpiCriticalCount"), "No completed scan yet");
  assert.equal(text("kpiRemediationOverdue"), "No risks in the register");
});

test("the live posture explainer adds up to the score it explains", () => {
  const { api } = run(true, LIVE);
  const out = api.liveScoreExplainer("posture");
  assert.match(out.html, /Risk Posture: 61 \/ 100/);
  const deducted = [...out.html.matchAll(/-(\d+) pts/g)].reduce((a: number, m: RegExpMatchArray) => a + Number(m[1]), 0);
  assert.equal(100 - deducted, 61);
  assert.doesNotMatch(out.html, /RSK-10\d|OneTrust|Subresource/);
});

test("every live explainer is built from data, and the modal hides the sample benchmark for it", () => {
  const { api } = run(true, LIVE);
  for (const k of ["posture", "controls", "evidence", "remediation"]) assert.ok(api.liveScoreExplainer(k), `no live explainer for ${k}`);
  assert.match(app, /if \(benchmark\) benchmark\.hidden = !!live;/);
  assert.match(app, /const live = isLiveWorkspace\(\) \? liveScoreExplainer\(scoreKey\) : null;/);
});

test("renderOverview fills the tiles, and scan evidence is never labelled Approved", () => {
  assert.match(app, /function renderOverview\(\) \{\n      renderOverviewKpis\(\);/);
  assert.doesNotMatch(app, /reviewer: 'CavScope engine', status: 'Approved'/);
  assert.match(app, /reviewer: 'Not reviewed', status: 'Captured'/);
});

test("a report whose sections did not load says so, never 'No report yet'", () => {
  // cavscope_website_overview returns latest_sitrep as a stub with no sections;
  // until 2026-09-28 app.html never fetched the rest, so a real tenant's tile
  // said "No report yet" beside a report that existed.
  const stub = { ...LIVE, overview: { ...LIVE.overview, latest_sitrep: { id: 129, headline: "x", posture_score: 71 } } };
  const { text } = run(true, stub);
  assert.equal(text("kpiControlCoverage"), "—");
  assert.equal(text("kpiControlsMet"), "Report did not load");
  assert.equal(text("kpiEvidenceReadiness"), "23", "evidence comes from the scan, not the report");
});
