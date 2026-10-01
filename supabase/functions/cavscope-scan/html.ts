// HTML text extraction for the scan engine. Pure, no I/O, so it can be unit
// tested -- which is the point: the client-rendered check used to live inline in
// runScan() and shipped with a defect nothing could catch.

/**
 * Visible text of an HTML fragment, tags removed and whitespace collapsed.
 *
 * `<[^>]*>` stops at the FIRST `>`, which is fine for the small fragments the
 * rules pass it (a title, a link's inner HTML) and NOT fine for a whole
 * document -- see stripToBodyText.
 */
export function stripTags(s: string): string {
  return s.replace(/<[^>]*>/g, "").replace(/\s+/g, " ").trim();
}

/**
 * Text a reader would actually see, given a whole HTML document.
 *
 * Order matters and is the whole fix:
 *
 * 1. **Comments first.** A comment's prose can contain `>` (`Admin -> Sources`)
 *    or a literal `-->`, and `stripTags`'s `<[^>]*>` ends at that first `>` and
 *    leaks the rest of the comment as body text. A comment can also contain
 *    `</script>`, which would break step 2 if that ran first.
 * 2. **`<head>` next.** `<title>` is not script, style or noscript, so its text
 *    counts as page content unless the head is removed.
 * 3. **Then script, style and noscript**, which carry no reader-visible text.
 */
export function stripToBodyText(html: string): string {
  return stripTags(
    html
      .replace(/<!--[\s\S]*?-->/g, "")
      .replace(/<head\b[\s\S]*?<\/head>/gi, "")
      .replace(/<(script|style|noscript)\b[\s\S]*?<\/\1>/gi, ""),
  );
}

/** Below this many characters of body text, a page that ships script is treated as client-rendered. */
export const CSR_TEXT_THRESHOLD = 200;

/**
 * Does this document render its content in the browser rather than ship it?
 *
 * A client-rendered app sends almost no markup, so the HTTP engine cannot see
 * what a reader sees. Findings derived from the markup are then downgraded and
 * annotated rather than reported as confident, because the alternative is
 * telling a client they have a defect on a page the engine never read.
 *
 * Before 2026-09-15 this measured text that included the `<title>` and the tail
 * of any comment containing a `>`. A Vite SPA shell whose real body was
 * `<div id="root"></div>` measured 411 characters against the 200 threshold and
 * was classified server-rendered, so `PRIV-001` reported at medium severity and
 * medium confidence with no caveat. See issue #93.
 *
 * The script test deliberately reads the ORIGINAL html: the question is whether
 * the page ships script at all, and steps 1-3 above have removed it by then.
 */
export function detectClientRendered(html: string): boolean {
  return stripToBodyText(html).length < CSR_TEXT_THRESHOLD && /<script\b/i.test(html);
}
