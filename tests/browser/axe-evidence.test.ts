// How one page's axe results are stored. Ingest keeps 8,192 characters of an evidence row; this keeps what
// matters inside that, first, and says what it left out.
//   node --experimental-strip-types --test tests/browser/axe-evidence.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
// @ts-ignore
import { axeEvidenceBody, EVIDENCE_LIMIT } from "../../workers/browser-scan/lib/axe-evidence.mjs";

const node = (i: number) => ({ target: [`.item-${i}`], html: `<div class="item-${i}" style="color:#999">some long markup ${"x".repeat(200)}</div>`, message: "Element has insufficient colour contrast" });
const viol = (id: string, n: number, impact = "serious") => ({ id, impact, help: `${id} help text that is fairly long to take space`, nodeCount: n, nodes: Array.from({ length: Math.min(n, 25) }, (_, i) => node(i)) });
const failing = (n: number) => Array.from({ length: n }, (_, i) => ({ target: `.cell-${i}`, status: "fail", ratio: 1.5 + i / 100, required: 4.5, reason: "weakest point across the gradient stops" }));
const big = () => ({
  axe: { version: "4.13.0", tags: ["wcag2a"], injection: "devtools_evaluate (page CSP unchanged)", passes: 40, violations: Array.from({ length: 30 }, (_, i) => viol(`rule-${i}`, 5 + i)), incomplete: Array.from({ length: 12 }, (_, i) => ({ id: `review-${i}`, help: "needs a person", nodes: [node(i)] })) },
  contrast: [...failing(180), { target: ".img", status: "unresolved", reason: "background is an image" }, ...Array.from({ length: 90 }, (_, i) => ({ target: `.ok-${i}`, status: "pass", ratio: 7, required: 4.5 }))],
});

test("a real page's results (tens of KB raw) fit inside the evidence limit", () => {
  const raw = JSON.stringify(big());
  assert.ok(raw.length > 30_000, `the fixture is big enough to matter: ${raw.length}`);
  const body = axeEvidenceBody(big());
  assert.ok(body.length <= EVIDENCE_LIMIT, `${body.length} <= ${EVIDENCE_LIMIT}`);
  JSON.parse(body); // still valid JSON, not a sliced one
});

test("the summary and the contrast failures come first, so a cut at 8,000 characters still keeps them", () => {
  const body = axeEvidenceBody(big());
  const o = JSON.parse(body);
  assert.deepEqual(Object.keys(o).slice(0, 2), ["summary", "contrastFailures"]);
  assert.ok(body.indexOf('"contrastFailures"') < body.indexOf('"violations"'));
  assert.ok(o.contrastFailures.length > 0);
  assert.ok(o.contrastFailures[0].ratio <= o.contrastFailures.at(-1).ratio, "weakest first");
  assert.equal(o.summary.contrast.resolvedFail, 180, "the count is the true count even though the list is trimmed");
  assert.equal(o.summary.contrast.resolvedPass, 90);
  assert.equal(o.summary.contrast.unresolved, 1);
  assert.equal(o.summary.violationRules, 30);
});

test("what was trimmed is stated, never silent", () => {
  const o = JSON.parse(axeEvidenceBody(big()));
  assert.equal(o.summary.shrunkToFit, true);
  assert.ok(o.summary.omitted.contrastFailures > 0);
  assert.ok(o.summary.omitted.violationNodes > 0);
  assert.ok(o.contrastFailures.length + o.summary.omitted.contrastFailures === 180);
});

test("violations are listed most-affected first and keep their rule ids, impact and element counts", () => {
  const o = JSON.parse(axeEvidenceBody(big()));
  assert.equal(o.violations[0].id, "rule-29");
  assert.equal(o.violations[0].elements, 34);
  assert.equal(o.violations[0].impact, "serious");
  assert.ok(o.violations.every((v: any) => v.id && v.elements > 0));
});

test("a small page is stored whole, with nothing omitted", () => {
  const o = JSON.parse(axeEvidenceBody({ axe: { version: "4.13.0", tags: [], injection: "x", passes: 10, violations: [viol("image-alt", 2)], incomplete: [] }, contrast: failing(2) }));
  assert.equal(o.summary.shrunkToFit, false);
  assert.deepEqual(o.summary.omitted, { contrastFailures: 0, violationNodes: 0 });
  assert.equal(o.contrastFailures.length, 2);
  assert.equal(o.violations[0].examples.length, 2);
});

test("an absurd page still never exceeds the limit", () => {
  const huge = { axe: { version: "4.13.0", tags: [], injection: "x", passes: 1, violations: Array.from({ length: 400 }, (_, i) => viol(`r${i}`, 300)), incomplete: [] }, contrast: failing(500) };
  assert.ok(axeEvidenceBody(huge).length <= EVIDENCE_LIMIT);
});
