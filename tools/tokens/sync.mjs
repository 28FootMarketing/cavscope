// Writes the :root block from assets/tokens.css into every page's <style>.
//
// The pages are self-contained by design -- see the header of assets/tokens.css
// for why the tokens are inlined rather than linked. That decision is only safe
// if something puts the same block in every page and something else proves it
// stayed there; this script is the first half, tests/ui/design-tokens.test.ts is
// the second.
//
//   node tools/tokens/sync.mjs          rewrite every page
//   node tools/tokens/sync.mjs --check  exit 1 if any page has drifted
//
// It replaces the region between the muster:tokens markers. On a page that has
// no markers yet it replaces that page's first :root {...} block and adds them,
// which is what made the initial adoption a single command.

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");

export const PAGES = [
  "index.html",
  "app.html",
  "signin.html",
  "onboarding.html",
  "sitrep.html",
  "sitrep-sample.html",
  "privacy.html",
];

const START = "/* muster:tokens:start -- generated from assets/tokens.css by tools/tokens/sync.mjs. Do not edit here. */";
const END = "/* muster:tokens:end */";

// Pull the :root block out of the source file, dropping the file-level comment
// that explains the rule -- that belongs in the source, not in seven copies of
// the output. Comments INSIDE the block are kept: they group the tokens.
export function canonicalBlock(css) {
  const open = css.indexOf(":root {");
  if (open === -1) throw new Error("assets/tokens.css has no :root block");
  const close = css.indexOf("\n}", open);
  if (close === -1) throw new Error("assets/tokens.css has an unterminated :root block");
  return css.slice(open, close + 2);
}

// Pages indent their <style> contents by four spaces. Re-indent rather than
// hardcoding, so the generated block sits where a reader expects it.
export function indentBlock(block, indent) {
  return block
    .split("\n")
    .map((line) => (line.trim() === "" ? "" : indent + line))
    .join("\n");
}

export function renderRegion(block, indent) {
  return [indent + START, indentBlock(block, indent), indent + END].join("\n");
}

// Returns the page with its token region replaced, or null if there is nothing
// to replace -- which is a hard error, not a no-op, because a page that silently
// keeps its own tokens is exactly the drift this is meant to stop.
export function applyToPage(html, block) {
  const markerStart = html.indexOf(START);
  if (markerStart !== -1) {
    const markerEnd = html.indexOf(END, markerStart);
    if (markerEnd === -1) return null;
    const lineStart = html.lastIndexOf("\n", markerStart) + 1;
    const indent = html.slice(lineStart, markerStart);
    return html.slice(0, lineStart) + renderRegion(block, indent) + html.slice(markerEnd + END.length);
  }

  const rootAt = html.indexOf(":root {");
  if (rootAt === -1) return null;
  const closeAt = html.indexOf("\n    }", rootAt);
  if (closeAt === -1) return null;
  const lineStart = html.lastIndexOf("\n", rootAt) + 1;
  const indent = html.slice(lineStart, rootAt);
  return html.slice(0, lineStart) + renderRegion(block, indent) + html.slice(closeAt + "\n    }".length);
}

export function loadCanonical() {
  return canonicalBlock(readFileSync(join(ROOT, "assets", "tokens.css"), "utf8"));
}

function main() {
  const check = process.argv.includes("--check");
  const block = loadCanonical();
  let drifted = 0;

  for (const page of PAGES) {
    const path = join(ROOT, page);
    const html = readFileSync(path, "utf8");
    const next = applyToPage(html, block);
    if (next === null) {
      console.error(`${page}: no token region and no :root block to adopt`);
      process.exitCode = 1;
      continue;
    }
    if (next === html) continue;
    drifted += 1;
    if (check) {
      console.error(`${page}: token block differs from assets/tokens.css`);
    } else {
      writeFileSync(path, next);
      console.log(`${page}: updated`);
    }
  }

  if (check && drifted > 0) {
    console.error(`\n${drifted} page(s) out of sync. Run: node tools/tokens/sync.mjs`);
    process.exitCode = 1;
  } else if (check) {
    console.log(`${PAGES.length} pages in sync with assets/tokens.css`);
  } else if (drifted === 0) {
    console.log(`${PAGES.length} pages already in sync`);
  }
}

if (process.argv[1] && process.argv[1].endsWith("sync.mjs")) main();
