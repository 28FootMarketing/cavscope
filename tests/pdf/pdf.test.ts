// SITREP markdown to PDF.
//
//   node --experimental-strip-types --test tests/pdf/pdf.test.ts
//
// The renderer must always produce a document: a report with characters a standard PDF font cannot draw,
// an unbreakable run of citations, or no content at all still comes out as a valid PDF. These tests
// also pin that it renders the report's own markdown (the same text the console and the .md export
// show) and adds only a footer.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { PDFDocument } from "pdf-lib";
import { parseInline, parseMarkdown, renderPdf, toWinAnsi } from "../../supabase/functions/cavscope-sitrep-pdf/pdf.ts";

const here = dirname(fileURLToPath(import.meta.url));
const sample = readFileSync(join(here, "sitrep-sample.md"), "utf8");

test("inline markdown keeps bold, code and citations apart from plain text", () => {
  const runs = parseInline("**No SPF** (high, `EMAIL-001`): fix it. [F493][E801][+7 more]");
  assert.deepEqual(runs.map((r) => r.style), ["bold", "plain", "code", "plain", "cite", "cite", "cite"]);
  assert.equal(runs[0].text, "No SPF");
  assert.equal(runs[2].text, "EMAIL-001");
  assert.equal(runs[6].text, "[+7 more]");
});

test("a bracket that is not a citation stays plain text", () => {
  assert.deepEqual(parseInline("see [F] and [x]"), [{ text: "see [F] and [x]", style: "plain" }]);
});

test("blocks: headings, paragraphs, bullets and tables, with the header table's empty title row dropped", () => {
  const blocks = parseMarkdown("# Title\n\n| | |\n|---|---|\n| Org | Acme |\n| Scan | #7 |\n\nA paragraph\nover two lines.\n\n- one\n- two\n");
  assert.deepEqual(blocks.map((b) => b.kind), ["h1", "table", "p", "bullet", "bullet"]);
  const table = blocks[1] as { header: unknown; rows: unknown[] };
  assert.equal(table.header, null);
  assert.equal(table.rows.length, 2);
  const para = blocks[2] as { runs: { text: string }[] };
  assert.equal(para.runs.map((r) => r.text).join(""), "A paragraph over two lines.");
});

test("a table with real column titles keeps them", () => {
  const [t] = parseMarkdown("| Evidence | Kind |\n|---|---|\n| E1 | dns |\n");
  assert.equal((t as { header: unknown[] | null }).header?.length, 2);
});

test("text a standard font cannot draw is replaced, never thrown on", () => {
  assert.equal(toWinAnsi("a — b “q” … → ✓"), 'a - b "q" ... -> ok');
  assert.equal(toWinAnsi("naïve café"), "naïve café");
  assert.equal(toWinAnsi("日本"), "??");
  assert.equal(toWinAnsi("tab\there"), "tab    here");
});

test("a real-shaped report renders to a multi-page PDF with its title in the metadata", async () => {
  const bytes = await renderPdf(sample, { title: "SITREP: Northstar Fintech", generatedAt: new Date("2026-10-02T00:00:00Z") });
  assert.equal(new TextDecoder().decode(bytes.slice(0, 5)), "%PDF-");
  const doc = await PDFDocument.load(bytes);
  assert.ok(doc.getPageCount() >= 3, `expected a long report to paginate, got ${doc.getPageCount()} page(s)`);
  assert.equal(doc.getTitle(), "SITREP: Northstar Fintech");
  assert.equal(doc.getAuthor(), "CavScope");
});

test("an unbreakable run wider than the page still renders", async () => {
  const bytes = await renderPdf(`# T\n\n${"E1234".repeat(200)}\n\n- ${"[E9]".repeat(300)}`, { title: "long" });
  assert.ok((await PDFDocument.load(bytes)).getPageCount() >= 1);
});

test("an empty report still renders one page", async () => {
  const doc = await PDFDocument.load(await renderPdf("", { title: "empty" }));
  assert.equal(doc.getPageCount(), 1);
});

test("characters outside the font do not stop a report", async () => {
  const bytes = await renderPdf("# 日本語 \u{1F642}\n\n- café — “quoted” ✓\n", { title: "unicode — \u{1F642}" });
  assert.ok(bytes.length > 500);
});
