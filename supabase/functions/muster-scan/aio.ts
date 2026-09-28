// AI-readiness (AIO / GEO) checks for the scan engine. Pure, no I/O, so each
// verdict can be pinned by a test -- the same reason html.ts exists.
//
// These back three rules the workspace's AIO view had been selling as pillars
// with nothing behind them: until http-native-1.8.0 the engine never requested
// /llms.txt and never read a JSON-LD block, and the view printed "llms.txt ->
// HTTP 404" and "Schema.org Organization found" for every domain typed into it.
//
// What none of this claims: that an AI assistant will cite the site. Providers
// decide that. These are readiness signals a crawler can observe in the served
// bytes, and the finding text says so.

/** Parse outcome of the /llms.txt probe. `ok` means a real llms.txt, not merely a 200. */
export type LlmsTxtVerdict = { ok: boolean; reason: string };

/**
 * Is this response an llms.txt file?
 *
 * A 200 is not enough: a single-page app answers every path with its HTML shell,
 * so a status-only check would credit every SPA with an llms.txt it does not
 * have. The proposal (llmstxt.org) requires a Markdown file whose first content
 * is an H1 naming the project, so that is the signature checked.
 */
export function assessLlmsTxt(r: { status: number | null; contentType: string | null; body: string; error?: string | null }): LlmsTxtVerdict {
  if (r.status === null) return { ok: false, reason: `request failed${r.error ? ` (${r.error.slice(0, 120)})` : ""}` };
  if (r.status >= 300 && r.status < 400) return { ok: false, reason: `HTTP ${r.status} (a redirect, not a file at the site root)` };
  if (r.status !== 200) return { ok: false, reason: `HTTP ${r.status}` };
  if (/text\/html|application\/xhtml/i.test(r.contentType ?? "") || /^\s*<(!doctype|html)\b/i.test(r.body)) {
    return { ok: false, reason: "HTTP 200 but an HTML page, not a text file (usually a site-wide catch-all route)" };
  }
  const first = r.body.split(/\r?\n/).map((l) => l.trim()).find((l) => l.length > 0);
  if (!first) return { ok: false, reason: "HTTP 200 with an empty body" };
  if (!/^#\s+\S/.test(first)) return { ok: false, reason: "HTTP 200 but the file does not open with a Markdown H1 (\"# Name\"), which the llms.txt format requires" };
  return { ok: true, reason: `present; titled "${first.replace(/^#\s+/, "").slice(0, 120)}"` };
}

/** What the homepage's JSON-LD blocks declare. */
export type JsonLdSummary = { blocks: number; parsed: number; types: string[] };

const LD_BLOCK = /<script\b[^>]*\btype\s*=\s*["']?application\/ld\+json["']?[^>]*>([\s\S]*?)<\/script>/gi;

function collectTypes(node: unknown, out: Set<string>, depth = 0): void {
  if (depth > 8 || node === null || typeof node !== "object") return;
  if (Array.isArray(node)) { for (const n of node) collectTypes(n, out, depth + 1); return; }
  const o = node as Record<string, unknown>;
  const t = o["@type"];
  if (typeof t === "string") out.add(t);
  else if (Array.isArray(t)) for (const x of t) if (typeof x === "string") out.add(x);
  // Only the top level and @graph declare entities; nested values (an Offer
  // inside a Product) are properties, and counting them would overstate what
  // the page tells a crawler it is.
  if (depth === 0 || o["@graph"]) collectTypes(o["@graph"], out, depth + 1);
}

/**
 * Every `<script type="application/ld+json">` block in a document: how many
 * there are, how many parse, and the entity types they declare.
 *
 * A block that fails JSON.parse is counted but contributes no types. Crawlers
 * discard it too, so reporting it as structured data would credit the site with
 * something no consumer can read.
 */
export function summarizeJsonLd(html: string): JsonLdSummary {
  const types = new Set<string>();
  let blocks = 0; let parsed = 0;
  for (const m of html.matchAll(LD_BLOCK)) {
    blocks++;
    const raw = m[1].trim().replace(/^<!\[CDATA\[/, "").replace(/\]\]>$/, "").trim();
    try { collectTypes(JSON.parse(raw), types); parsed++; } catch { /* unparseable: counted, not credited */ }
  }
  return { blocks, parsed, types: [...types].sort() };
}
