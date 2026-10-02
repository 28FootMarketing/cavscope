// SITREP markdown to PDF. Pure and dependency-light: only pdf-lib, whose standard fonts
// (Helvetica, Helvetica-Bold, Courier) supply the glyph widths used for wrapping, so the layout
// is computed here rather than by a browser. There is no headless browser in this project, which
// is why this renders the report's own markdown instead of the page.
//
// Why the markdown: it is the one form of a SITREP that is the same document everywhere. The
// console shows it verbatim, `.md` export carries it, and the PDF now renders it, so the three can
// not disagree. It never adds words of its own beyond a page footer and the document metadata.
//
// Everything outside what a standard PDF font can encode is replaced with a plain-text stand-in
// rather than dropped silently or thrown: a report must always render.
import { PDFDocument, StandardFonts, rgb, type PDFFont, type PDFPage } from "pdf-lib";

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

export type Run = { text: string; style: "plain" | "bold" | "code" | "cite" };
export type Block =
  | { kind: "h1" | "h2" | "h3" | "p"; runs: Run[] }
  | { kind: "bullet"; runs: Run[]; depth: number }
  | { kind: "table"; header: Run[][] | null; rows: Run[][][] };

const CITE = /\[(?:[FE]\d+|\+\d+ more)\]/y;

/** Split one line of inline markdown into styled runs. Handles **bold**, `code` and [F12]/[E3] citations. */
export function parseInline(text: string): Run[] {
  const runs: Run[] = [];
  let buf = "";
  const flush = () => { if (buf) { runs.push({ text: buf, style: "plain" }); buf = ""; } };
  let i = 0;
  while (i < text.length) {
    if (text.startsWith("**", i)) {
      const end = text.indexOf("**", i + 2);
      if (end > i + 2) { flush(); runs.push({ text: text.slice(i + 2, end), style: "bold" }); i = end + 2; continue; }
    }
    if (text[i] === "`") {
      const end = text.indexOf("`", i + 1);
      if (end > i + 1) { flush(); runs.push({ text: text.slice(i + 1, end), style: "code" }); i = end + 1; continue; }
    }
    if (text[i] === "[") {
      CITE.lastIndex = i;
      const m = CITE.exec(text);
      if (m) { flush(); runs.push({ text: m[0], style: "cite" }); i += m[0].length; continue; }
    }
    buf += text[i];
    i++;
  }
  flush();
  return runs;
}

const splitRow = (line: string): string[] =>
  line.trim().replace(/^\|/, "").replace(/\|$/, "").split("|").map((c) => c.trim());
const isSeparator = (line: string) => /^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$/.test(line);

export function parseMarkdown(md: string): Block[] {
  const lines = md.replace(/\r\n?/g, "\n").split("\n");
  const blocks: Block[] = [];
  let para: string[] = [];
  const endPara = () => {
    if (para.length) blocks.push({ kind: "p", runs: parseInline(para.join(" ")) });
    para = [];
  };
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (!line.trim()) { endPara(); continue; }
    const h = /^(#{1,3})\s+(.*)$/.exec(line);
    if (h) { endPara(); blocks.push({ kind: (`h${h[1].length}`) as "h1" | "h2" | "h3", runs: parseInline(h[2]) }); continue; }
    if (line.trimStart().startsWith("|") && i + 1 < lines.length && isSeparator(lines[i + 1])) {
      endPara();
      const head = splitRow(line);
      const rows: Run[][][] = [];
      i += 2;
      while (i < lines.length && lines[i].trimStart().startsWith("|")) { rows.push(splitRow(lines[i]).map(parseInline)); i++; }
      i--;
      // `| | |` is how the report header says "no column titles".
      blocks.push({ kind: "table", header: head.every((c) => c === "") ? null : head.map(parseInline), rows });
      continue;
    }
    const b = /^(\s*)[-*]\s+(.*)$/.exec(line);
    if (b) { endPara(); blocks.push({ kind: "bullet", runs: parseInline(b[2]), depth: Math.min(2, Math.floor(b[1].length / 2)) }); continue; }
    para.push(line.trim());
  }
  endPara();
  return blocks;
}

// ---------------------------------------------------------------------------
// Text a standard font can encode
// ---------------------------------------------------------------------------

const STAND_INS: Record<string, string> = {
  "‘": "'", "’": "'", "“": '"', "”": '"', "–": "-", "—": "-", "−": "-",
  "…": "...", "•": "-", " ": " ", "→": "->", "←": "<-", "≥": ">=", "≤": "<=",
  "✓": "ok", "✗": "x", "×": "x", "​": "", "️": "",
};

/** Map text onto what Helvetica/Courier (WinAnsi) can draw: common typography to ASCII, the rest of Latin-1 kept, anything else '?'. */
export function toWinAnsi(s: string): string {
  let out = "";
  for (const ch of s) {
    const mapped = STAND_INS[ch];
    if (mapped !== undefined) { out += mapped; continue; }
    const c = ch.codePointAt(0)!;
    if (c === 9) out += "    ";
    else if (c < 32 || (c >= 127 && c < 160)) out += "";
    else if (c <= 255) out += ch;
    else out += "?";
  }
  return out;
}

// ---------------------------------------------------------------------------
// Layout
// ---------------------------------------------------------------------------

const PAGE = { w: 612, h: 792, mx: 54, top: 60, bottom: 62 };
const COLORS = { ink: rgb(0.047, 0.082, 0.153), body: rgb(0.14, 0.18, 0.26), muted: rgb(0.36, 0.44, 0.56), rule: rgb(0.85, 0.88, 0.92), accent: rgb(0.21, 0.89, 0.79), cite: rgb(0.45, 0.52, 0.64), band: rgb(0.024, 0.039, 0.086) };

type Fonts = { plain: PDFFont; bold: PDFFont; code: PDFFont };
type Word = { text: string; font: PDFFont; size: number; color: ReturnType<typeof rgb>; gapBefore: boolean };

function styleOf(run: Run, fonts: Fonts, size: number, base: ReturnType<typeof rgb>): { font: PDFFont; size: number; color: ReturnType<typeof rgb> } {
  if (run.style === "bold") return { font: fonts.bold, size, color: base };
  if (run.style === "code") return { font: fonts.code, size: size - 0.5, color: COLORS.ink };
  if (run.style === "cite") return { font: fonts.plain, size: Math.max(6.5, size - 2.5), color: COLORS.cite };
  return { font: fonts.plain, size, color: base };
}

/** Break runs into drawable words. A word too wide for the column is split by character. */
function toWords(runs: Run[], fonts: Fonts, size: number, base: ReturnType<typeof rgb>, maxW: number): Word[] {
  const words: Word[] = [];
  let gap = false; // whitespace seen since the last word, carried across runs
  for (const run of runs) {
    const st = styleOf(run, fonts, size, base);
    const text = toWinAnsi(run.text);
    // Citation chains run together with no spaces; allow a break between the brackets.
    const pieces = run.style === "cite" ? [text] : text.split(/(\s+)/);
    for (const piece of pieces) {
      if (piece === "") continue;
      if (/^\s+$/.test(piece)) { gap = true; continue; }
      let rest = piece;
      while (st.font.widthOfTextAtSize(rest, st.size) > maxW) {
        let n = rest.length;
        while (n > 1 && st.font.widthOfTextAtSize(rest.slice(0, n), st.size) > maxW) n--;
        words.push({ text: rest.slice(0, n), font: st.font, size: st.size, color: st.color, gapBefore: gap });
        gap = false;
        rest = rest.slice(n);
      }
      words.push({ text: rest, font: st.font, size: st.size, color: st.color, gapBefore: gap });
      gap = false;
    }
  }
  return words;
}

function wrap(words: Word[], maxW: number): Word[][] {
  const lines: Word[][] = [];
  let line: Word[] = [];
  let w = 0;
  for (const word of words) {
    const space = line.length && word.gapBefore ? word.font.widthOfTextAtSize(" ", word.size) : 0;
    const ww = word.font.widthOfTextAtSize(word.text, word.size);
    if (line.length && w + space + ww > maxW) { lines.push(line); line = []; w = 0; }
    const sp = line.length && word.gapBefore ? word.font.widthOfTextAtSize(" ", word.size) : 0;
    line.push(word);
    w += sp + ww;
  }
  if (line.length) lines.push(line);
  return lines;
}

export type Meta = { title: string; subtitle?: string; generatedAt?: Date };

export async function renderPdf(md: string, meta: Meta): Promise<Uint8Array> {
  const doc = await PDFDocument.create();
  doc.setTitle(toWinAnsi(meta.title));
  doc.setAuthor("CavScope");
  doc.setProducer("CavScope");
  doc.setCreator("CavScope SITREP export");
  doc.setCreationDate(meta.generatedAt ?? new Date());
  const fonts: Fonts = {
    plain: await doc.embedFont(StandardFonts.Helvetica),
    bold: await doc.embedFont(StandardFonts.HelveticaBold),
    code: await doc.embedFont(StandardFonts.Courier),
  };

  let page: PDFPage = doc.addPage([PAGE.w, PAGE.h]);
  let y = PAGE.h - PAGE.top;
  const contentW = PAGE.w - 2 * PAGE.mx;
  const newPage = () => { page = doc.addPage([PAGE.w, PAGE.h]); y = PAGE.h - PAGE.top; };
  const need = (h: number) => { if (y - h < PAGE.bottom) newPage(); };

  // Title band on the first page only; the footer carries the brand on every page.
  page.drawRectangle({ x: 0, y: PAGE.h - 34, width: PAGE.w, height: 34, color: COLORS.band });
  page.drawRectangle({ x: 0, y: PAGE.h - 37, width: PAGE.w, height: 3, color: COLORS.accent });
  page.drawText("CavScope", { x: PAGE.mx, y: PAGE.h - 23, size: 13, font: fonts.bold, color: rgb(0.95, 0.96, 1) });
  page.drawText("SITREP", { x: PAGE.w - PAGE.mx - fonts.plain.widthOfTextAtSize("SITREP", 9), y: PAGE.h - 22, size: 9, font: fonts.plain, color: rgb(0.7, 0.78, 0.9) });

  const drawLines = (lines: Word[][], x: number, lineH: number) => {
    for (const line of lines) {
      need(lineH);
      let cx = x;
      for (const w of line) {
        if (w.gapBefore && cx > x) cx += w.font.widthOfTextAtSize(" ", w.size);
        page.drawText(w.text, { x: cx, y: y - w.size, size: w.size, font: w.font, color: w.color });
        cx += w.font.widthOfTextAtSize(w.text, w.size);
      }
      y -= lineH;
    }
  };

  const textBlock = (runs: Run[], size: number, base: ReturnType<typeof rgb>, indent: number, lineH: number, bold = false) => {
    const r = bold ? runs.map((x) => (x.style === "plain" ? { ...x, style: "bold" as const } : x)) : runs;
    const lines = wrap(toWords(r, fonts, size, base, contentW - indent), contentW - indent);
    drawLines(lines, PAGE.mx + indent, lineH);
  };

  for (const b of parseMarkdown(md)) {
    if (b.kind === "h1") {
      need(34); textBlock(b.runs, 19, COLORS.ink, 0, 24, true); y -= 4;
      page.drawRectangle({ x: PAGE.mx, y: y + 2, width: 44, height: 2, color: COLORS.accent }); y -= 12;
    } else if (b.kind === "h2") {
      need(40); y -= 8; textBlock(b.runs, 13.5, COLORS.ink, 0, 18, true); y -= 3;
    } else if (b.kind === "h3") {
      need(30); y -= 4; textBlock(b.runs, 11, COLORS.ink, 0, 15, true); y -= 2;
    } else if (b.kind === "p") {
      textBlock(b.runs, 10, COLORS.body, 0, 13.5); y -= 5;
    } else if (b.kind === "bullet") {
      const indent = 14 + b.depth * 14;
      need(14);
      page.drawCircle({ x: PAGE.mx + indent - 8, y: y - 6.4, size: 1.6, color: COLORS.muted });
      textBlock(b.runs, 10, COLORS.body, indent, 13.5); y -= 3;
    } else {
      const cols = Math.max(b.header?.length ?? 0, ...b.rows.map((r) => r.length), 1);
      // Column widths follow what the columns hold: the widest single-line cell in each, clamped
      // so one long URL cannot starve the others, then scaled to fill the page.
      const natural = Array.from({ length: cols }, (_, c) => {
        const cells = [b.header?.[c], ...b.rows.map((r) => r[c])].filter(Boolean) as Run[][];
        return Math.max(40, ...cells.map((cell) => toWords(cell, fonts, 9, COLORS.body, 1e6).reduce((w, x, i) => w + x.font.widthOfTextAtSize(x.text, x.size) + (i && x.gapBefore ? 3 : 0), 0) + 8));
      }).map((w) => Math.min(w, 250));
      const sum = natural.reduce((a, c) => a + c, 0);
      const colW = natural.map((w) => (w / sum) * contentW);
      const drawRow = (cells: Run[][], isHead: boolean) => {
        const pad = 4;
        const wrapped = colW.map((cw, c) => wrap(toWords(cells[c] ?? [], fonts, 9, isHead ? COLORS.ink : COLORS.body, cw - 2 * pad), cw - 2 * pad));
        const rowH = Math.max(1, ...wrapped.map((l) => l.length)) * 12 + 2 * pad;
        need(rowH);
        let cx = PAGE.mx;
        wrapped.forEach((lines, c) => {
          let ly = y - pad;
          for (const line of lines) {
            let lx = cx + pad;
            for (const w of line) {
              if (w.gapBefore && lx > cx + pad) lx += w.font.widthOfTextAtSize(" ", w.size);
              const font = isHead || (cols === 2 && c === 0) ? fonts.bold : w.font;
              page.drawText(w.text, { x: lx, y: ly - w.size, size: w.size, font, color: w.color });
              lx += font.widthOfTextAtSize(w.text, w.size);
            }
            ly -= 12;
          }
          cx += colW[c];
        });
        y -= rowH;
        page.drawLine({ start: { x: PAGE.mx, y }, end: { x: PAGE.mx + contentW, y }, thickness: 0.5, color: COLORS.rule });
      };
      if (b.header) drawRow(b.header, true);
      for (const r of b.rows) drawRow(r, false);
      y -= 8;
    }
  }

  // Footer on every page, drawn last so it can say "of N".
  const pages = doc.getPages();
  const footer = "CavScope, website assurance by 28 Foot Systems";
  pages.forEach((p, i) => {
    p.drawLine({ start: { x: PAGE.mx, y: 46 }, end: { x: PAGE.w - PAGE.mx, y: 46 }, thickness: 0.5, color: COLORS.rule });
    p.drawText(footer, { x: PAGE.mx, y: 32, size: 8, font: fonts.plain, color: COLORS.muted });
    const label = `Page ${i + 1} of ${pages.length}`;
    p.drawText(label, { x: PAGE.w - PAGE.mx - fonts.plain.widthOfTextAtSize(label, 8), y: 32, size: 8, font: fonts.plain, color: COLORS.muted });
  });
  return await doc.save();
}
