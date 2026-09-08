// Push docs/ into MUSTER's retrieval corpus.
//
//   MUSTER_FUNCTIONS_URL=https://hjowfnzpomzxazmzywxw.supabase.co/functions/v1 \
//   MUSTER_CRON_SECRET=... \
//   node --experimental-strip-types tools/embed-docs/sync.ts [--dry-run] [docs/ONE.md ...]
//
// This tool holds no inference credential and never talks to OpenRouter. It reads
// the repository, chunks it (tools/embed-docs/chunk.ts), and posts text. The edge
// function muster-embed-docs holds the OpenRouter key and does the writing. That
// split is the point: the sync can run from a laptop or CI with nothing but the
// shared secret, and the key stays in the edge runtime where it is already set.
//
// Re-running it against unchanged docs is free -- the function compares content
// hashes and skips anything that has not moved -- so running it after every docs/
// edit is the intended habit, not an event.

import { readFileSync } from "node:fs";
import { chunkMarkdown, type ChunkedDoc } from "./chunk.ts";

const MANIFEST_PATH = new URL("./manifest.json", import.meta.url).pathname;

function loadManifest(): Record<string, string> {
  const raw = JSON.parse(readFileSync(MANIFEST_PATH, "utf8"));
  return raw.docs ?? {};
}

function fail(message: string): never {
  console.error(`sync: ${message}`);
  process.exit(1);
}

async function main() {
  const args = process.argv.slice(2);
  const dryRun = args.includes("--dry-run");
  const only = args.filter((a) => !a.startsWith("--"));

  const base = process.env.MUSTER_FUNCTIONS_URL;
  const secret = process.env.MUSTER_CRON_SECRET;
  if (!base) fail("MUSTER_FUNCTIONS_URL is not set (e.g. https://<project>.supabase.co/functions/v1)");
  if (!secret) fail("MUSTER_CRON_SECRET is not set");

  const manifest = loadManifest();

  // A doc named on the command line still has to be classified. Defaulting an
  // unlisted file to 'public' would publish internal notes to every tenant on a
  // typo; defaulting it to 'internal' silently would hide a doc someone meant to
  // publish. Refusing is the only option that cannot be wrong quietly.
  const paths = only.length > 0 ? only : Object.keys(manifest);
  for (const p of paths) {
    if (!(p in manifest)) fail(`${p} is not in tools/embed-docs/manifest.json -- classify it as "public" or "internal" first`);
  }

  const documents: ChunkedDoc[] = [];
  for (const path of paths) {
    const visibility = manifest[path];
    if (visibility === "none") { console.log(`skip     ${path} (visibility: none)`); continue; }
    if (visibility !== "public" && visibility !== "internal") {
      fail(`${path} has visibility ${JSON.stringify(visibility)} in the manifest; expected "public", "internal" or "none"`);
    }
    let markdown: string;
    try {
      markdown = readFileSync(path, "utf8");
    } catch {
      fail(`${path} is in the manifest but not on disk -- remove it from the manifest, or restore the file`);
    }
    const doc = await chunkMarkdown(path, markdown, visibility);
    if (doc.chunks.length === 0) { console.log(`skip     ${path} (no content)`); continue; }
    console.log(`chunked  ${path.padEnd(26)} ${visibility.padEnd(8)} ${String(doc.chunks.length).padStart(3)} chunks  ~${doc.chunks.reduce((a, c) => a + c.token_estimate, 0)} tokens`);
    documents.push(doc);
  }

  if (documents.length === 0) fail("nothing to sync");

  const res = await fetch(`${base.replace(/\/$/, "")}/muster-embed-docs`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-muster-secret": secret },
    body: JSON.stringify({ documents, dry_run: dryRun }),
  });

  const payload = await res.json().catch(() => ({}));
  if (!res.ok || payload.ok !== true) {
    console.error(JSON.stringify(payload, null, 2));
    fail(`muster-embed-docs returned ${res.status}`);
  }

  console.log("");
  for (const r of payload.results) {
    console.log(`${dryRun ? "would embed" : "embedded"}  ${r.doc_path.padEnd(26)} ${String(r.embedded).padStart(3)} changed  ${String(r.unchanged).padStart(3)} unchanged  ${String(r.pruned).padStart(3)} pruned`);
  }
  const s = payload.summary;
  console.log(`\n${dryRun ? "DRY RUN — nothing written. " : ""}${s.documents} documents, ${s.embedded} chunks ${dryRun ? "would be embedded" : "embedded"}, ${s.unchanged} unchanged, ${s.pruned} pruned.`);
}

main().catch((e) => fail(e.message));
