// Every [data-tooltip] element must be reachable by keyboard, not just mouse.
//
//   node --experimental-strip-types --test tests/ui/tooltip-reachability.test.ts
//
// CLAUDE.md's tooltip engine (initTooltips, copied verbatim onto every page)
// shows a tooltip on focusin as well as mouseover, and calls itself
// "accessible (keyboard focus, Escape to dismiss, aria-describedby)". That
// claim was false for most of the tooltips on the site: a plain <span>,
// <div>, <td>, <p>, <h2>, <aside> or <footer> carrying data-tooltip is never
// focusable on its own, so a keyboard-only or screen-reader user tabbing
// through the page skips straight over it and never learns the engine has
// anything to say about that element. A real end-to-end sweep with a headless
// browser found 148 such elements across seven of the eight pages -- every
// page except signin.html, which happened to only ever put data-tooltip on
// inputs and buttons.
//
// The fix is mechanical: a data-tooltip element that isn't a naturally
// focusable tag (a[href], button, input, textarea, select) needs
// tabindex="0", unless it's legitimately disabled (a disabled control is
// correctly out of the tab order regardless) or the tooltip lives on a
// <label for="..."> whose target control already gets focus -- in which case
// the tooltip belongs on the control itself (see signin.html's own inputs),
// not the label, so focusing the field is what shows it.
//
// This is pinned here, not left to the next silent regression: a new
// data-tooltip on a <div> or <span> with no tabindex is a defect on a
// product that sells accessibility auditing (A11Y-001..007) -- shipping
// exactly what it scans for.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const read = (p: string) => readFileSync(join(repoRoot, p), "utf8");

const PAGES = [
  "index.html", "app.html", "signin.html", "onboarding.html",
  "sitrep.html", "sitrep-sample.html", "privacy.html", "admin.html",
];

const NATURALLY_FOCUSABLE = new Set(["a", "button", "input", "textarea", "select"]);

/**
 * Every raw `<tag ... data-tooltip="...">` opening tag in the source. Quote-
 * aware, so a `>` (or `<`) inside an attribute value -- plenty of tooltip
 * strings contain one -- doesn't get mistaken for the tag boundary.
 */
function tooltipTags(html: string): string[] {
  const tags: string[] = [];
  let i = html.indexOf("data-tooltip=");
  while (i !== -1) {
    const start = html.lastIndexOf("<", i);
    let end = -1;
    let inQuote: string | null = null;
    for (let j = start; j < html.length; j++) {
      const c = html[j];
      if (inQuote) {
        if (c === inQuote) inQuote = null;
        continue;
      }
      if (c === '"' || c === "'") { inQuote = c; continue; }
      if (c === ">") { end = j; break; }
    }
    if (end === -1) break;
    tags.push(html.slice(start, end + 1));
    i = html.indexOf("data-tooltip=", end);
  }
  return tags;
}

for (const page of PAGES) {
  test(`${page}: every data-tooltip element is keyboard-reachable`, () => {
    const html = read(page);
    const offenders: string[] = [];
    for (const tag of tooltipTags(html)) {
      const tagName = tag.match(/^<([a-zA-Z0-9]+)/)?.[1]?.toLowerCase();
      if (!tagName) continue;
      if (/\bdisabled(\s|=|>)/.test(tag)) continue; // correctly out of tab order
      if (/\btabindex\s*=/.test(tag)) continue;
      if (NATURALLY_FOCUSABLE.has(tagName)) {
        if (tagName === "a" && !/\shref\s*=/.test(tag)) offenders.push(tag);
        continue;
      }
      // A <label for="..."> is the one shape that's allowed to skip
      // tabindex: the tooltip belongs on the labelled control, not here.
      if (tagName === "label" && /\sfor\s*=/.test(tag)) continue;
      offenders.push(tag);
    }
    assert.deepEqual(
      offenders,
      [],
      `${offenders.length} data-tooltip element(s) on ${page} are not keyboard-reachable ` +
        `(no tabindex, not a natural focus target): ${offenders.slice(0, 3).join(" | ")}`,
    );
  });
}

test("sitrep.html puts the auth field tooltips on the inputs, not their labels", () => {
  const sitrep = read("sitrep.html");
  assert.match(sitrep, /<input type="email" id="authEmail"[^>]*data-tooltip="/);
  assert.match(sitrep, /<input type="password" id="authPassword"[^>]*data-tooltip="/);
  assert.doesNotMatch(sitrep, /<label for="authEmail"[^>]*data-tooltip=/);
  assert.doesNotMatch(sitrep, /<label for="authPassword"[^>]*data-tooltip=/);
});
