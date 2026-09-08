// The chunker decides what the agent can retrieve and how it can cite it. Both
// halves are worth pinning: a chunk that loses its heading stops being findable
// by its subject, and an anchor that does not match GitHub's turns every citation
// into a dead link.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { chunkMarkdown, slugify, splitLongSection, sha256, MAX_CHUNK_CHARS } from "../../tools/embed-docs/chunk.ts";

test("slugify matches GitHub for a plain heading", () => {
  assert.equal(slugify("How the product groups these"), "how-the-product-groups-these");
});

test("slugify keeps the double hyphen an em dash leaves behind", () => {
  // GitHub drops the em dash and turns both surrounding spaces into hyphens.
  // Collapsing them to one would link to a heading that does not exist.
  assert.equal(slugify("Email authentication — 7 rules"), "email-authentication--7-rules");
});

test("slugify drops punctuation but keeps digits", () => {
  assert.equal(slugify("Path B — application email (2026)"), "path-b--application-email-2026");
});

test("the document title becomes the doc_title, not a chunk heading", async () => {
  const doc = await chunkMarkdown("docs/X.md", "# The Title\n\nOpening line.\n\n## First\n\nBody.\n", "public");
  assert.equal(doc.doc_title, "The Title");
  assert.deepEqual(doc.chunks.map((c) => c.heading), ["The Title", "First"]);
});

test("content above the first ## is kept, not dropped", async () => {
  const doc = await chunkMarkdown("docs/X.md", "# T\n\nWhy this document exists.\n\n## S\n\nBody.\n", "public");
  assert.match(doc.chunks[0].text, /Why this document exists/);
});

test("a document with no preamble produces no empty leading chunk", async () => {
  const doc = await chunkMarkdown("docs/X.md", "# T\n\n## S\n\nBody.\n", "public");
  assert.equal(doc.chunks.length, 1);
  assert.equal(doc.chunks[0].heading, "S");
});

test("every chunk carries the title and heading, so it embeds on its subject", async () => {
  const doc = await chunkMarkdown("docs/X.md", "# MUSTER scan rules\n\n## Email authentication\n\nMerge them into one.\n", "public");
  const chunk = doc.chunks.at(-1)!;
  assert.match(chunk.text, /MUSTER scan rules/);
  assert.match(chunk.text, /Email authentication/);
  assert.match(chunk.text, /Merge them into one/);
});

test("a ## inside a fenced block is sample output, not a heading", async () => {
  const md = "# T\n\n## Real\n\n```sh\n## not a heading\necho hi\n```\n\nAfter.\n";
  const doc = await chunkMarkdown("docs/X.md", md, "internal");
  assert.deepEqual(doc.chunks.map((c) => c.heading), ["Real"]);
  assert.match(doc.chunks[0].text, /## not a heading/);
});

test("chunk_index is dense and ordered", async () => {
  const md = "# T\n\n## A\n\na\n\n## B\n\nb\n\n## C\n\nc\n";
  const doc = await chunkMarkdown("docs/X.md", md, "internal");
  assert.deepEqual(doc.chunks.map((c) => c.chunk_index), [0, 1, 2]);
});

test("an empty section is not stored", async () => {
  const doc = await chunkMarkdown("docs/X.md", "# T\n\n## Empty\n\n## Full\n\nbody\n", "internal");
  assert.deepEqual(doc.chunks.map((c) => c.heading), ["Full"]);
});

test("the hash is of the stored text, so it changes when the text does", async () => {
  const a = await chunkMarkdown("docs/X.md", "# T\n\n## S\n\nbody\n", "public");
  const b = await chunkMarkdown("docs/X.md", "# T\n\n## S\n\nbody\n", "public");
  const c = await chunkMarkdown("docs/X.md", "# T\n\n## S\n\nbody two\n", "public");
  assert.equal(a.chunks[0].sha, b.chunks[0].sha);
  assert.notEqual(a.chunks[0].sha, c.chunks[0].sha);
  assert.equal(a.chunks[0].sha, await sha256(a.chunks[0].text));
  assert.match(a.chunks[0].sha, /^[0-9a-f]{64}$/);
});

test("splitLongSection never cuts inside a code fence", () => {
  const fence = "```\n" + "x".repeat(MAX_CHUNK_CHARS * 2) + "\n```";
  const body = "intro\n\n" + fence + "\n\ntail\n";
  const parts = splitLongSection(body, 500);
  for (const part of parts) {
    const fences = (part.match(/^\s*```/gm) ?? []).length;
    assert.equal(fences % 2, 0, `unbalanced fence in part: ${part.slice(0, 80)}`);
  }
});

test("splitLongSection leaves a short section alone", () => {
  assert.deepEqual(splitLongSection("short body"), ["short body"]);
});

test("splitLongSection actually splits prose that exceeds the cap", () => {
  const body = Array.from({ length: 40 }, (_, i) => `paragraph ${i} ${"y".repeat(60)}`).join("\n\n");
  const parts = splitLongSection(body, 500);
  assert.ok(parts.length > 1, "expected more than one part");
  assert.equal(parts.join("\n\n").replace(/\s+/g, " "), body.replace(/\s+/g, " "));
});

test("every docs/ file is classified in the manifest", () => {
  const manifest = JSON.parse(readFileSync("tools/embed-docs/manifest.json", "utf8")).docs;
  const onDisk = readdirSync("docs").filter((f) => f.endsWith(".md")).map((f) => `docs/${f}`);
  const missing = onDisk.filter((p) => !(p in manifest));
  assert.deepEqual(missing, [], `unclassified docs would default to internal by omission: ${missing.join(", ")}`);
  const stale = Object.keys(manifest).filter((p) => !onDisk.includes(p));
  assert.deepEqual(stale, [], `manifest names files that are not on disk: ${stale.join(", ")}`);
});

test("only documents deliberately marked public are public", () => {
  const manifest = JSON.parse(readFileSync("tools/embed-docs/manifest.json", "utf8")).docs;
  // Not a style rule. These describe project refs, RPC names, auth gates and the
  // impersonation protocol; marking one 'public' would publish it to every tenant
  // key, so the change has to be deliberate enough to edit this list too.
  const mustStayInternal = [
    "docs/BACKEND.md", "docs/CUTOVER.md", "docs/EMAIL.md", "docs/EMAIL-INVENTORY.md",
    "docs/IMPERSONATION.md", "docs/MAGIC-LINK.md", "docs/RETRIEVAL.md",
  ];
  for (const path of mustStayInternal) {
    if (path in manifest) assert.equal(manifest[path], "internal", `${path} must not be public`);
  }
});

test("every real doc chunks without producing an oversized chunk", async () => {
  const manifest = JSON.parse(readFileSync("tools/embed-docs/manifest.json", "utf8")).docs;
  for (const [path, visibility] of Object.entries(manifest)) {
    if (visibility === "none") continue;
    const doc = await chunkMarkdown(path, readFileSync(path, "utf8"), visibility as "public" | "internal");
    assert.ok(doc.chunks.length > 0, `${path} produced no chunks`);
    assert.notEqual(doc.doc_title, path, `${path} has no # title line`);
    for (const chunk of doc.chunks) {
      assert.ok(chunk.text.length <= MAX_CHUNK_CHARS * 2, `${path}#${chunk.chunk_index} is ${chunk.text.length} chars`);
      assert.ok(chunk.anchor.length > 0, `${path}#${chunk.chunk_index} has an empty anchor`);
    }
  }
});

test("anchors resolve to a heading that exists in the file", async () => {
  const manifest = JSON.parse(readFileSync("tools/embed-docs/manifest.json", "utf8")).docs;
  for (const [path, visibility] of Object.entries(manifest)) {
    if (visibility === "none") continue;
    const markdown = readFileSync(path, "utf8");
    const headings = new Set(
      markdown.split("\n").filter((l) => /^#{1,2}\s+/.test(l)).map((l) => slugify(l.replace(/^#{1,2}\s+/, "").trim())),
    );
    const doc = await chunkMarkdown(path, markdown, visibility as "public" | "internal");
    for (const chunk of doc.chunks) {
      assert.ok(headings.has(chunk.anchor), `${path}#${chunk.anchor} is not a heading in the file`);
    }
  }
});
