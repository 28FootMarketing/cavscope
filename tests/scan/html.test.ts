import { test } from "node:test";
import assert from "node:assert/strict";
import { CSR_TEXT_THRESHOLD, detectClientRendered, stripToBodyText, stripTags } from "../../supabase/functions/muster-scan/html.ts";

// Regression tests for issue #93. Each case here is a way the old inline check
// counted text a reader never sees, and so called a client-rendered page
// server-rendered -- which reported PRIV-001 at medium severity and medium
// confidence on a page the engine could not read.

const shell = (extra = "") =>
  `<!doctype html><html lang="en"><head><title>A Long Enough Title To Matter Here</title></head><body>${extra}<div id="root"></div><script type="module" src="/a.js"></script></body></html>`;

test("an empty SPA shell is client-rendered", () => {
  assert.equal(detectClientRendered(shell()), true);
  assert.equal(stripToBodyText(shell()), "");
});

test("the <title> does not count as body text", () => {
  // The old check stripped only script/style/noscript, so title text survived.
  const html = `<!doctype html><html><head><title>${"x".repeat(400)}</title></head><body><div id="root"></div><script src="/a.js"></script></body></html>`;
  assert.equal(stripToBodyText(html), "");
  assert.equal(detectClientRendered(html), true);
});

test("a comment containing '>' does not leak its tail as body text", () => {
  // `<[^>]*>` ends at the first `>`, so everything after it in the comment used
  // to read as text. This is the exact shape found on anthonywashingtonsr.com.
  const html = shell(`<!-- Colour is managed from Admin -> Sources, so ${"this line never changes. ".repeat(20)} -->`);
  assert.equal(stripToBodyText(html), "");
  assert.equal(detectClientRendered(html), true);
});

test("a comment containing a literal --> does not leak either", () => {
  const html = shell(`<!-- the block below is noscript-only --> and ${"would otherwise leak. ".repeat(20)}`.replace(" and ", "<!-- "));
  assert.equal(detectClientRendered(html), true);
});

test("a comment containing </script> does not break the script strip", () => {
  // Comments are removed first for exactly this reason.
  const html = shell(`<!-- do not ship </script> in a comment -->`);
  assert.equal(stripToBodyText(html), "");
  assert.equal(detectClientRendered(html), true);
});

test("a noscript crawler fallback is not counted as rendered content", () => {
  // It is real content for a crawler, but it is not what the SPA renders, and
  // the rules that care are asking what a browser would show.
  const html = shell(`<noscript><h1>Fallback</h1><p>${"summary prose ".repeat(40)}</p></noscript>`);
  assert.equal(detectClientRendered(html), true);
});

test("a server-rendered page is not client-rendered, even with script and comments", () => {
  const html = `<!doctype html><html lang="en"><head><title>T</title></head><body><!-- a -> b --><h1>Real</h1><p>${"server rendered prose ".repeat(20)}</p><script src="/a.js"></script></body></html>`;
  assert.ok(stripToBodyText(html).length > CSR_TEXT_THRESHOLD);
  assert.equal(detectClientRendered(html), false);
});

test("a page with no script at all is never client-rendered", () => {
  // Nothing could render it in the browser, so an empty body is just an empty page.
  assert.equal(detectClientRendered("<!doctype html><html><body></body></html>"), false);
});

test("a head with no closing tag falls back rather than throwing", () => {
  // Malformed input must not crash a scan; the non-greedy head strip simply
  // does not match, and the check degrades to its old behaviour.
  assert.doesNotThrow(() => detectClientRendered("<html><head><title>T</title><body><script src=/a.js></script>"));
});

test("stripTags still collapses whitespace for the fragment callers", () => {
  // A11Y-002, A11Y-007 and PRIV-001 pass it small fragments, not documents.
  assert.equal(stripTags("  <b>Privacy</b>\n  &nbsp;policy "), "Privacy &nbsp;policy");
  assert.equal(stripTags("<span></span>"), "");
});
