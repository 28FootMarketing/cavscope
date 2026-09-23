// The AIO / GEO audit view, tested by running its builder on real payload shapes.
//
//   node --experimental-strip-types --test tests/ui/aio-view.test.ts
//
// Live.buildAio is extracted from app.html rather than copied, so an edit to it
// runs these assertions against the edit.
//
// What was wrong before 2026-09-23, and what each test below pins:
//
// - "Run AIO Audit" printed a scripted terminal -- "llms.txt -> HTTP 404",
//   "Schema.org Organization found", "empty <div id=root> shell" -- for every
//   domain, signed in or not. Nothing was requested.
// - The live index was the site's overall SECURITY posture relabelled.
// - llms.txt and structured data were pillars with no engine rule behind them.
// - A check whose rule had never run (inactive, or a scan from an older engine)
//   had no finding, and so scored as a pass. Absence of findings is not a pass.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const html = readFileSync(join(repoRoot, "app.html"), "utf8");

type Check = { rule: string; state: "pass" | "fail" | "na"; note: string; label: string };
type Aio = {
  live: boolean; overallScore: number | null; badge: string; summary: string; checks: Check[];
  pillars: Array<{ id: string; score: number | null; rationale: string }>;
  findings: Array<{ priority: string; pillar: string; points: string }>;
  blocker: { id: string | null; title: string }; jsonLd: string; llmsTxt: string;
};

function loadLive(ruleStatus: Array<{ rule_id: string; active: boolean }> | null) {
  const start = html.indexOf("      // ---------- AIO / GEO audit ----------");
  const end = html.indexOf("      async runAioAudit(log) {");
  assert.notEqual(start, -1, "AIO section not found in app.html");
  assert.ok(end > start, "extraction anchors are out of order");
  const members = html.slice(start, end);
  const obj = new Function(`return ({ ${members}
    host(u) { try { return new URL(u).host; } catch (_) { return u || ''; } },
  });`)() as Record<string, unknown> & { buildAio: (o: unknown, ov: unknown, site: unknown, demo: unknown) => Aio };
  (obj as Record<string, unknown>).ruleStatus = ruleStatus;
  return obj;
}

const ALL_ACTIVE = ["GOV-001", "GOV-002", "GOV-003", "GOV-004", "GOV-005", "GOV-006", "GOV-007", "GOV-008", "A11Y-002"]
  .map((rule_id) => ({ rule_id, active: true }));
const HELD = ALL_ACTIVE.map((r) => ({ ...r, active: !["GOV-006", "GOV-007", "GOV-008"].includes(r.rule_id) }));

const org = { name: "Hanover Borough" };
const site = { url: "https://hanoverboroughpa.gov/" };
const scan = (engine_version: string) => ({ id: 91, status: "complete", engine_version, finished_at: "2026-09-23T04:00:00Z" });
const finding = (rule_id: string, severity: string, detail: string) =>
  ({ rule_id, severity, title: rule_id + " title", detail, remediation: "fix " + rule_id, page_url: site.url, evidence_ids: [501] });

const ov = (engine: string, findings: unknown[], posture = 41) =>
  ({ posture_score: posture, findings, recent_scans: [{ id: 92, status: "queued" }, scan(engine)] });

test("the index is its own, not the security posture relabelled", () => {
  const live = loadLive(ALL_ACTIVE);
  const aio = live.buildAio(org, ov("http-native-1.8.0", [
    finding("GOV-006", "info", "GET /llms.txt: HTTP 404."),
    finding("GOV-004", "info", "Addressed: GPTBot. Fully blocked: none."),
  ], 12), site, {});
  // 8 of 9 checks pass. Posture was 12; the index must not be.
  assert.equal(aio.overallScore, 89);
  assert.equal(aio.badge, "8 of 9 checks pass");
  assert.equal(aio.checks.find((c) => c.rule === "GOV-006")!.state, "fail");
  assert.equal(aio.checks.find((c) => c.rule === "GOV-004")!.state, "pass");
  assert.equal(aio.blocker.id, "GOV-006");
});

test("a held rule is not assessed, never a pass", () => {
  const aio = loadLive(HELD).buildAio(org, ov("http-native-1.8.0", []), site, {});
  for (const rule of ["GOV-006", "GOV-007", "GOV-008"]) {
    const c = aio.checks.find((x) => x.rule === rule)!;
    assert.equal(c.state, "na", `${rule} is inactive, so it cannot have fired`);
    assert.match(c.note, /not enabled yet/);
  }
  assert.equal(aio.pillars.find((p) => p.id === "llms")!.score, null);
  assert.equal(aio.pillars.find((p) => p.id === "schema")!.score, null);
  // GOV-004 always reports on a readable robots.txt; absent, it is not a pass.
  assert.equal(aio.checks.find((c) => c.rule === "GOV-004")!.state, "na");
});

test("a scan from an engine older than the rule is not assessed", () => {
  const aio = loadLive(ALL_ACTIVE).buildAio(org, ov("http-native-1.7.1", []), site, {});
  for (const rule of ["GOV-006", "GOV-007", "GOV-008"]) {
    assert.equal(aio.checks.find((x) => x.rule === rule)!.state, "na");
  }
  assert.equal(aio.checks.find((x) => x.rule === "GOV-003")!.state, "pass", "a long-standing rule with no finding passes");
  // Version compare is numeric, not lexical: 1.10.0 is past 1.8.0.
  const later = loadLive(ALL_ACTIVE).buildAio(org, ov("http-native-1.10.0", []), site, {});
  assert.equal(later.checks.find((x) => x.rule === "GOV-006")!.state, "pass");
});

test("an unread homepage assesses nothing", () => {
  const aio = loadLive(ALL_ACTIVE).buildAio(org, ov("http-native-1.8.0", [finding("AVAIL-003", "critical", "HTTP 403")]), site, {});
  assert.ok(aio.checks.every((c) => c.state === "na"));
  assert.equal(aio.overallScore, null);
  assert.equal(aio.badge, "Not assessed yet");
});

test("unknown rule status and no completed scan both fail closed", () => {
  assert.ok(loadLive(null).buildAio(org, ov("http-native-1.8.0", []), site, {}).checks.every((c) => c.state === "na"));
  const none = loadLive(ALL_ACTIVE).buildAio(org, { findings: [], recent_scans: [{ id: 1, status: "failed" }] }, site, {});
  assert.equal(none.overallScore, null);
  assert.match(none.summary, /No completed scan/);
});

test("citability is never scored", () => {
  const aio = loadLive(ALL_ACTIVE).buildAio(org, ov("http-native-1.8.0", []), site, {});
  const c = aio.pillars.find((p) => p.id === "citability")!;
  assert.equal(c.score, null);
  assert.match(c.rationale, /not assessed/i);
});

test("implementation assets carry only what MUSTER holds", () => {
  const aio = loadLive(ALL_ACTIVE).buildAio(org, ov("http-native-1.8.0", [
    finding("GOV-006", "info", "x"), finding("GOV-007", "info", "y"),
  ]), site, {});
  // The sample invented /platform, /security, /docs/api and a logo path.
  for (const invented of ["/platform", "/security", "/docs/api", "logo.png", "SoftwareApplication"]) {
    assert.ok(!aio.jsonLd.includes(invented) && !aio.llmsTxt.includes(invented), `${invented} must not appear`);
  }
  assert.match(aio.jsonLd, /"name": "Hanover Borough"/);
  const ld = aio.jsonLd.match(/<script type="application\/ld\+json">\n([\s\S]*?)\n<\/script>/);
  assert.ok(ld, "JSON-LD block present");
  assert.equal(JSON.parse(ld![1])["@graph"][0].url, "https://hanoverboroughpa.gov/");
  assert.match(aio.llmsTxt, /^# Hanover Borough\n/);

  const done = loadLive(ALL_ACTIVE).buildAio(org, ov("http-native-1.8.0", []), site, {});
  assert.match(done.llmsTxt, /found a valid \/llms\.txt/);
  assert.match(done.jsonLd, /found readable JSON-LD/);
});

test("findings cite evidence, sorted by severity", () => {
  const aio = loadLive(ALL_ACTIVE).buildAio(org, ov("http-native-1.8.0", [
    finding("GOV-006", "info", "a"), finding("GOV-008", "low", "b"),
  ]), site, {});
  assert.deepEqual(aio.findings.map((f) => f.pillar), ["Crawlability & Rendering · GOV-008", "LLM Surface (/llms.txt) · GOV-006"]);
  assert.equal(aio.findings[0].points, "E501");
});

test("the button runs the engine in a live workspace, and the sample says it is scripted", () => {
  const exec = html.slice(html.indexOf("    async function executeAioAudit() {"), html.indexOf("    function renderAioResults() {"));
  assert.match(exec, /if \(isLiveWorkspace\(\)\) \{\s*await Live\.runAioAudit\(log\);/);
  // Every scripted line is labelled as a sample.
  const scripted = [...exec.matchAll(/log\(`([^`]*)`/g)].map((m) => m[1]);
  assert.ok(scripted.length >= 5);
  for (const line of scripted) assert.match(line, /^\[SAMPLE\]/, `unlabelled scripted line: ${line}`);

  const run = html.slice(html.indexOf("      async runAioAudit(log) {"), html.indexOf("      // ---------- scans ----------"));
  assert.match(run, /this\.rpc\('muster_request_scan'/);
  assert.match(run, /status === 'failed'/);
  assert.match(run, /n < 40/, "polling is bounded");
});

test("the universal audit never invents an accessibility score for a live tenant", () => {
  const uni = html.slice(html.indexOf("    async function runUniversalAudit() {"), html.indexOf("    function setScanDomain("));
  const liveBranch = uni.indexOf("if (isLiveWorkspace()) {");
  const random = uni.indexOf("state.accessibility.overallScore = Math.floor(82 + Math.random()");
  assert.ok(liveBranch !== -1 && random > liveBranch, "the live branch must return before the sample's random score");
});
