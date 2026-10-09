// Runs the browser engine's accessibility collection (axe-core, plus the contrast cases axe cannot settle)
// over THIS repo's own pages, served as https://cavscope.28footsystems.com/..., so a page change can be
// checked before it ships. Nothing is written anywhere.
//
//   cd workers/browser-scan && npm install      (once)
//   node tools/site-axe/run.mjs                 every page
//   node tools/site-axe/run.mjs /,/privacy      some pages
//   DETAIL=1 node tools/site-axe/run.mjs /app   the failing elements
//
// Pages behind a session (/admin, /audit/html) bounce to the landing page when signed out, so they report
// the landing page's numbers; their signed-in panels are not covered here.
// Serves this repo's own pages as https://cavscope.28footsystems.com/... and runs the browser engine's axe
// collection over them. Other https hosts go out through Node (fonts, CDN); Supabase calls are refused.
import { readFileSync, existsSync } from "node:fs";
import { chromium } from "../../workers/browser-scan/node_modules/playwright-core/index.mjs";
import { collectPage, newScanContext, AXE_VERSION } from "../../workers/browser-scan/lib/collect.mjs";
import { evaluateAxe, evaluateStructure } from "../../workers/browser-scan/lib/rules.mjs";
const R = new URL("../..", import.meta.url).pathname.replace(/\/$/, "");
const ORIGIN = "https://cavscope.28footsystems.com";
const MAP = { "/": "index.html", "/signin": "signin.html", "/onboarding": "onboarding.html", "/sitrep": "sitrep.html", "/sitrep/sample": "sitrep-sample.html", "/privacy": "privacy.html", "/terms": "terms.html", "/app": "app.html", "/admin": "admin.html", "/audit/html": "html-audit.html" };
const only = process.argv[2] ? process.argv[2].split(",") : Object.keys(MAP);
const browser = await chromium.launch();
const ctx = await newScanContext(browser);
await ctx.route(/^https?:/, async (route) => {
  const u = new URL(route.request().url());
  if (u.origin === ORIGIN) {
    const f = MAP[u.pathname] ? `${R}/${MAP[u.pathname]}` : `${R}${u.pathname}`;
    if (existsSync(f) && !f.endsWith("/")) {
      const ext = f.split(".").pop();
      const type = { html: "text/html", css: "text/css", js: "text/javascript", png: "image/png", svg: "image/svg+xml", ico: "image/x-icon", webp: "image/webp", txt: "text/plain", json: "application/json" }[ext] ?? "application/octet-stream";
      return route.fulfill({ status: 200, contentType: type, body: readFileSync(f) });
    }
    return route.fulfill({ status: 404, body: "not found" });
  }
  if (/supabase\.co/.test(u.host)) return route.abort("blockedbyclient");
  try {
    const res = await fetch(u.toString(), { headers: { "user-agent": route.request().headers()["user-agent"] ?? "x" } });
    const headers = {}; res.headers.forEach((v, k) => { if (!["content-encoding", "content-length", "transfer-encoding", "connection"].includes(k)) headers[k] = v; });
    return route.fulfill({ status: res.status, headers, body: Buffer.from(await res.arrayBuffer()) });
  } catch { return route.abort("failed"); }
});
const pages = [];
for (const [i, path] of only.entries()) pages.push(await collectPage(ctx, ORIGIN + path, { first: false, evidenceKey: `page_${i + 1}`, observeForms: false }));
for (const p of pages) {
  if (p.error) { console.log("LOAD ERROR", p.url, p.error); continue; }
  const v = (p.axe?.violations ?? []).map((x) => `${x.id}(${x.nodeCount ?? x.nodes.length},${x.impact})`).join(" ");
  const cf = (p.contrast ?? []).filter((c) => c.status === "fail").length, cp = (p.contrast ?? []).filter((c) => c.status === "pass").length, cu = (p.contrast ?? []).filter((c) => c.status === "unresolved").length;
  const inc = (p.axe?.incomplete ?? []).filter((x) => x.id !== "color-contrast").map((x) => x.id).join(",");
  console.log(`${new URL(p.url).pathname.padEnd(16)} violations: ${v || "none"} | contrast pass/fail/unres ${cp}/${cf}/${cu} | review: ${inc || "-"}`);
}
if (process.env.DETAIL) {
  for (const p of pages) for (const v of p.axe?.violations ?? []) { console.log(`\n## ${new URL(p.url).pathname} ${v.id}: ${v.help}`); for (const n of v.nodes.slice(0, 3)) console.log("   ", n.target.join(" "), "::", n.html.slice(0, 150).replace(/\s+/g, " "), "::", n.failureSummary.replace(/\s+/g, " ").slice(0, 200)); }
  for (const p of pages) { const f = (p.contrast ?? []).filter((c) => c.status === "fail"); if (f.length) { for (const c of f.slice(0,5)) console.log("   FAIL", c.ratio, c.required, c.target); console.log(`\n## ${new URL(p.url).pathname} resolved contrast FAILURES (${f.length})`); const byT = {}; for (const c of f) byT[c.target] = c.ratio; Object.entries(byT).slice(0, 12).forEach(([t, r]) => console.log("   ", r, t)); } }
}
await browser.close();
