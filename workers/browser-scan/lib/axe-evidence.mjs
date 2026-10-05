// The stored form of one page's axe results. Ingest keeps the first 8,192 characters of each evidence row
// (the sha-256 still covers whatever was captured), and a real page's axe JSON is 13 to 48 KB, so with the
// raw dump the part a person needs most, the resolved contrast failures at the END, was the part cut off.
//
// So this is written for the cut: the summary and the failures come FIRST, then violations most-affected
// first, then what needs review; and the body is shrunk in steps until it fits, saying what it left out.
// Nothing is lost silently, and the whole body is what gets hashed, so the stored text is exactly what the
// hash covers.

export const EVIDENCE_LIMIT = 8000;

const LEVELS = [
  { nodes: 5, html: 160, contrast: 40, incompleteNodes: 2 },
  { nodes: 3, html: 110, contrast: 25, incompleteNodes: 1 },
  { nodes: 2, html: 80, contrast: 12, incompleteNodes: 1 },
  { nodes: 1, html: 60, contrast: 6, incompleteNodes: 0 },
  { nodes: 1, html: 40, contrast: 3, incompleteNodes: 0 },
];

const cut = (s, n) => { const t = String(s ?? ""); return t.length > n ? t.slice(0, n - 1) + "…" : t; };

export function axeEvidenceBody({ axe, contrast = [], limit = EVIDENCE_LIMIT }) {
  const failing = contrast.filter((c) => c.status === "fail").sort((a, b) => a.ratio - b.ratio);
  const unresolved = contrast.filter((c) => c.status === "unresolved");
  const passed = contrast.filter((c) => c.status === "pass").length;
  const violations = [...(axe.violations ?? [])].sort((a, b) => (b.nodeCount ?? b.nodes?.length ?? 0) - (a.nodeCount ?? a.nodes?.length ?? 0));
  const incomplete = [...(axe.incomplete ?? [])].filter((i) => i.id !== "color-contrast");

  let body = "";
  for (const [step, L] of LEVELS.entries()) {
    const omitted = {
      contrastFailures: Math.max(0, failing.length - L.contrast),
      violationNodes: violations.reduce((n, v) => n + Math.max(0, (v.nodeCount ?? v.nodes?.length ?? 0) - Math.min(L.nodes, v.nodes?.length ?? 0)), 0),
    };
    const obj = {
      summary: {
        axeVersion: axe.version, tags: axe.tags, injection: axe.injection, rulesPassed: axe.passes,
        violationRules: violations.length, violationElements: violations.reduce((n, v) => n + (v.nodeCount ?? v.nodes?.length ?? 0), 0),
        needsReviewRules: incomplete.length,
        contrast: { resolvedPass: passed, resolvedFail: failing.length, unresolved: unresolved.length },
        shrunkToFit: step > 0, omitted,
      },
      contrastFailures: failing.slice(0, L.contrast).map((c) => ({ target: cut(c.target, 80), ratio: c.ratio, required: c.required, why: cut(c.reason, 60) })),
      contrastUnresolved: unresolved.slice(0, 6).map((c) => ({ target: cut(c.target, 80), why: cut(c.reason, 70) })),
      violations: violations.map((v) => ({
        id: v.id, impact: v.impact, help: cut(v.help, 90), elements: v.nodeCount ?? v.nodes?.length ?? 0,
        examples: (v.nodes ?? []).slice(0, L.nodes).map((n) => ({ target: cut((n.target ?? []).join(" "), 90), html: cut(n.html, L.html) })),
      })),
      needsReview: incomplete.map((i) => ({
        id: i.id, help: cut(i.help, 80), elements: i.nodeCount ?? i.nodes?.length ?? 0,
        examples: (i.nodes ?? []).slice(0, L.incompleteNodes).map((n) => ({ target: cut((n.target ?? []).join(" "), 90), html: cut(n.html, L.html), message: cut(n.message, 100) })),
      })),
    };
    body = JSON.stringify(obj);
    if (body.length <= limit) return body;
  }
  // Still over after the smallest level: keep the front, which is the part that matters, and say so.
  return body.slice(0, limit - 40) + '…"[cut at the evidence limit]"';
}
