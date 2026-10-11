// Computes the Content-Security-Policy hashes for every page's inline script.
//
// Every page in this repo is one HTML file carrying its own <script> block(s)
// and, on five of them, onclick= / onchange= / onsubmit= / oninput= handlers
// written in the markup. Until 2026-10-11 the response's CSP allowed all of
// that with 'unsafe-inline' on script-src -- which is what CavScope's own
// SEC-018 reports ("a lock with the key left in it"), and on 2026-10-11 it
// reported it against this site (scan 332, finding 3378).
//
// The fix is the standard one. A CSP may name an inline script by the SHA-256
// of its exact text ('sha256-<base64>'), and with the 'unsafe-hashes' keyword
// it may name an inline event handler the same way. A browser then runs the
// inline code that is in the file and refuses anything injected, and
// 'unsafe-inline' goes. The cost is that the hashes must match the pages byte
// for byte, which is what this script and tests/routing/csp-inline.test.ts
// are for -- the same arrangement as the design tokens: this writes the
// manifest, the test fails if a page has drifted from it.
//
//   node tools/csp/sync.mjs          rewrite tools/csp/manifest.js
//   node tools/csp/sync.mjs --check  exit 1 if the manifest is stale
//
// Run it after any change to a page's <script> block or inline handlers,
// including a change made by another sync tool (tokens, support widget).
// A stale manifest is not cosmetic: in production the browser refuses the
// block whose hash no longer matches, and the page renders with no script.
//
// Two shapes of inline handler cannot be hashed and this script refuses them,
// because a wrong answer here ships a page whose buttons silently do nothing:
//   - a handler built from data, onclick="fn(${id})" inside a template
//     literal: its rendered text differs per row, so it has no one hash.
//     app.html dispatches those rows through data-act attributes instead
//     (initActionDelegation()).
//   - a handler whose attribute value contains an HTML entity this script does
//     not decode, or a backslash (a template-literal escape renders as a
//     different character than the source shows).
// Hashes are computed over the DECODED attribute value, which is what the
// browser hashes; &amp; &lt; &gt; &quot; &#39; &#039; &apos; are decoded here.

import { readFileSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

// The same list as tools/tokens/sync.mjs; tests/routing/csp-inline.test.ts asserts
// the two agree. Not imported from there, because that module runs its sync when
// argv[1] ends in sync.mjs, which this file's does too.
export const PAGES = [
  "index.html",
  "app.html",
  "signin.html",
  "onboarding.html",
  "sitrep.html",
  "sitrep-sample.html",
  "admin.html",
  "privacy.html",
  "terms.html",
  "beta.html",
  "html-audit.html",
];

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const MANIFEST = join(ROOT, "tools", "csp", "manifest.js");

const JS_TYPES = new Set(["", "text/javascript", "application/javascript", "module", "text/ecmascript", "application/ecmascript"]);

/** The CSP source expression for one piece of inline script: 'sha256-<base64>', quotes included. */
export function sha256(text) {
  return "'sha256-" + createHash("sha256").update(text, "utf8").digest("base64") + "'";
}

/** The text of every executable inline <script> in document order. */
export function inlineScripts(html) {
  const out = [];
  const re = /<script\b([^>]*)>([\s\S]*?)<\/script\s*>/gi;
  let m;
  while ((m = re.exec(html)) !== null) {
    const attrs = m[1];
    if (/\ssrc\s*=/i.test(attrs)) continue;
    const type = (attrs.match(/\stype\s*=\s*["']?([^"'\s>]*)/i) || [, ""])[1].toLowerCase();
    if (!JS_TYPES.has(type)) continue; // application/ld+json and the like never execute
    out.push(m[2]);
  }
  return out;
}

const ENTITIES = { "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": '"', "&#39;": "'", "&#039;": "'", "&apos;": "'" };

function decodeHandler(raw, where) {
  if (raw.includes("${")) {
    throw new Error(`${where}: inline handler built from data cannot be hashed: ${JSON.stringify(raw)}. Use a data-act attribute and the delegated listener instead.`);
  }
  if (raw.includes("\\")) {
    throw new Error(`${where}: inline handler contains a backslash, whose rendered text may differ from the source: ${JSON.stringify(raw)}`);
  }
  return raw.replace(/&[#a-z0-9]+;/gi, (e) => {
    if (!(e in ENTITIES)) throw new Error(`${where}: inline handler uses an entity this tool does not decode: ${e}`);
    return ENTITIES[e];
  });
}

/** Every distinct inline event-handler attribute value, decoded as the browser hashes it, sorted. */
export function inlineHandlers(html, where = "page") {
  const set = new Set();
  const re = /\son[a-z]+\s*=\s*(?:"([^"]*)"|'([^']*)')/gi;
  let m;
  while ((m = re.exec(html)) !== null) set.add(decodeHandler(m[1] ?? m[2] ?? "", where));
  return [...set].sort();
}

/** What the CSP has to name for this page: one hash per inline block, one per distinct handler. */
export function hashesFor(html, where = "page") {
  return {
    scripts: inlineScripts(html).map(sha256),
    handlers: inlineHandlers(html, where).map(sha256),
  };
}

export function buildManifest() {
  const out = {};
  for (const page of PAGES) out[page] = hashesFor(readFileSync(join(ROOT, page), "utf8"), page);
  return out;
}

export function renderManifest(manifest) {
  const lines = [
    "// GENERATED by tools/csp/sync.mjs -- do not edit. Run: node tools/csp/sync.mjs",
    "//",
    "// Per page, the 'sha256-...' sources middleware.js puts on script-src: one for",
    "// each inline <script> block and, under 'unsafe-hashes', one for each distinct",
    "// inline event handler. tests/routing/csp-inline.test.ts fails if a page has",
    "// changed and this file has not.",
    "export default {",
  ];
  for (const [page, h] of Object.entries(manifest)) {
    lines.push(`  ${JSON.stringify(page)}: {`);
    lines.push(`    scripts: [${h.scripts.map((x) => JSON.stringify(x)).join(", ")}],`);
    lines.push(`    handlers: [`);
    for (const x of h.handlers) lines.push(`      ${JSON.stringify(x)},`);
    lines.push(`    ],`);
    lines.push(`  },`);
  }
  lines.push("};", "");
  return lines.join("\n");
}

function main() {
  const check = process.argv.includes("--check");
  const next = renderManifest(buildManifest());
  let current = null;
  try { current = readFileSync(MANIFEST, "utf8"); } catch { current = null; }
  if (next === current) {
    console.log(`tools/csp/manifest.js is current (${PAGES.length} pages)`);
    return;
  }
  if (check) {
    console.error("tools/csp/manifest.js is stale. Run: node tools/csp/sync.mjs");
    process.exitCode = 1;
    return;
  }
  writeFileSync(MANIFEST, next);
  console.log(`tools/csp/manifest.js written (${PAGES.length} pages)`);
}

if (process.argv[1] && process.argv[1].endsWith("sync.mjs") && fileURLToPath(import.meta.url) === process.argv[1]) main();
