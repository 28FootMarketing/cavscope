// Markdown -> retrievable chunks. Pure, so the shape of what gets embedded is
// testable without a network call, an API key, or a database.
//
// The unit is a `##` section. That is not an arbitrary size choice: a section in
// these documents is already the unit a human would quote, it has a heading that
// names what it is, and it has a GitHub anchor -- so a retrieved chunk can be
// cited as docs/SCAN-RULES.md#email-authentication-7-rules and the reader lands on
// the exact text the agent read. Chunking by token count instead would retrieve
// fragments nobody can go verify, which defeats the point of the citation scheme
// the rest of CavScope already runs on.

/** One embeddable section of one document. */
export type DocChunk = {
  heading: string;
  anchor: string;
  chunk_index: number;
  text: string;
  sha: string;
  token_estimate: number;
};

export type ChunkedDoc = {
  doc_path: string;
  doc_title: string;
  visibility: "public" | "internal";
  chunks: DocChunk[];
};

/**
 * Characters, not tokens. text-embedding-3-small accepts ~8191 tokens; this cap
 * is deliberately far below it, because the point of the limit is not the API's
 * ceiling -- it is that a chunk large enough to cover four subjects matches every
 * query weakly and none of them well.
 */
export const MAX_CHUNK_CHARS = 6000;

/**
 * GitHub's heading-anchor rules, as far as these documents exercise them:
 * lowercase, drop anything that is not alphanumeric / space / hyphen, spaces to
 * hyphens. Em dashes and rule codes appear in CavScope headings, so both paths are
 * live -- "Email authentication — 7 rules" has to come out as
 * "email-authentication--7-rules", the same string GitHub puts in the URL, or the
 * citation links to nothing.
 */
export function slugify(heading: string): string {
  return String(heading || "")
    .trim()
    .toLowerCase()
    .replace(/[^\p{L}\p{N} \-]/gu, "")
    .replace(/ /g, "-");
}

/** Rough token count for cost reporting only. Never used to make a decision. */
export function estimateTokens(text: string): number {
  return Math.ceil(String(text || "").length / 4);
}

export async function sha256(text: string): Promise<string> {
  const bytes = new TextEncoder().encode(text);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

/**
 * Split a section that exceeds MAX_CHUNK_CHARS, on blank lines, without ever
 * cutting inside a fenced code block.
 *
 * The fence tracking is the part that matters. A naive paragraph split through a
 * ``` block produces two chunks that each contain one fence, so both render as
 * unterminated code for the rest of the document -- and worse, an agent quoting
 * one of them shows the reader half a command. Splitting only at depth zero
 * costs an occasional oversized chunk, which is the harmless direction.
 */
export function splitLongSection(body: string, maxChars = MAX_CHUNK_CHARS): string[] {
  if (body.length <= maxChars) return [body];

  const lines = body.split("\n");
  const parts: string[] = [];
  let current: string[] = [];
  let inFence = false;

  const flush = () => {
    if (current.length) parts.push(current.join("\n").replace(/\n+$/, ""));
    current = [];
  };

  for (const line of lines) {
    if (/^\s*(```|~~~)/.test(line)) inFence = !inFence;
    const wouldBe = current.join("\n").length + line.length + 1;
    // Break before this line, not after: a break point is a blank line at fence
    // depth zero, and only once there is something worth keeping on this side.
    if (!inFence && line.trim() === "" && wouldBe > maxChars && current.length > 0) {
      flush();
      continue;
    }
    current.push(line);
  }
  flush();
  return parts.filter((p) => p.trim().length > 0);
}

/**
 * Chunk one markdown document.
 *
 * Every chunk's text is prefixed with the document title and the section heading.
 * That is not decoration: the embedding is of the text as stored, and a section
 * body that reads "Merge them into one." carries no signal about SPF without the
 * heading above it. Prefixing is the cheapest way to keep a section retrievable
 * by the subject it is actually about.
 *
 * Content before the first `##` becomes chunk 0 under the document title, so a
 * doc's opening paragraphs -- often the part that says what the document is for --
 * are not silently dropped.
 */
export async function chunkMarkdown(
  doc_path: string,
  markdown: string,
  visibility: "public" | "internal",
): Promise<ChunkedDoc> {
  const lines = String(markdown || "").split("\n");

  let doc_title = doc_path;
  let sawTitle = false;
  const preamble: string[] = [];
  const sections: Array<{ heading: string; body: string[] }> = [];
  let current: { heading: string; body: string[] } | null = null;
  let inFence = false;

  for (const line of lines) {
    if (/^\s*(```|~~~)/.test(line)) inFence = !inFence;

    // A "## " inside a fence is sample output, not a heading. Treating it as one
    // splits a code block across two chunks and invents a section that does not
    // exist in the rendered document.
    if (!inFence) {
      const h2 = /^##\s+(.+?)\s*$/.exec(line);
      if (h2) {
        if (current) sections.push(current);
        current = { heading: h2[1], body: [] };
        continue;
      }
      if (!sawTitle && current === null) {
        const h1 = /^#\s+(.+?)\s*$/.exec(line);
        if (h1) {
          doc_title = h1[1];
          sawTitle = true;
          continue;
        }
      }
    }

    if (current) current.body.push(line);
    else preamble.push(line);
  }
  if (current) sections.push(current);

  // Whatever sat above the first "##" is a section in its own right, named after
  // the document. It is usually the paragraph that says what the document is for,
  // which is exactly what a "what is this" query should match.
  if (preamble.join("\n").trim()) {
    sections.unshift({ heading: doc_title, body: preamble });
  }

  const chunks: DocChunk[] = [];
  let index = 0;

  for (const section of sections) {
    const body = section.body.join("\n").trim();
    if (!body) continue;
    const anchor = slugify(section.heading);

    for (const part of splitLongSection(body)) {
      const text = `${doc_title} — ${section.heading}\n\n${part}`.trim();
      chunks.push({
        heading: section.heading,
        anchor,
        chunk_index: index++,
        text,
        sha: await sha256(text),
        token_estimate: estimateTokens(text),
      });
    }
  }

  return { doc_path, doc_title, visibility, chunks };
}
