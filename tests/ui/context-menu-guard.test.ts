// initContextMenuGuard, tested against the function actually shipped in every page.
//
//   node --experimental-strip-types --test tests/ui/context-menu-guard.test.ts
//
// The guard suppresses the context menu on a right-click. It was added at the
// owner's explicit request, with the tradeoff stated first: it does NOT protect
// page source (Ctrl+U, F12, curl, Save Page As and disabling JavaScript all still
// read every byte), and it must never be cited as a control.
//
// So what is worth testing is not that it blocks -- that part is one line. It is
// the two carve-outs, because those are what keep a deliberate speed bump from
// silently becoming an accessibility defect on a product that sells accessibility
// auditing:
//
//   1. Keyboard-invoked context menus (Menu key, Shift+F10) must still open, or
//      screen reader and keyboard-only users lose the menu entirely. They arrive
//      with button 0; a mouse right-click arrives with button 2.
//   2. Text-entry surfaces must keep their native menu, or paste and spellcheck
//      suggestions break in every form on the site -- for nothing, since a form
//      field exposes no source.
//
// Both are the kind of regression that ships quietly and is found by a user, so
// they are pinned here rather than left to review.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");

const PAGES = [
  "index.html", "app.html", "signin.html", "onboarding.html",
  "sitrep.html", "sitrep-sample.html", "privacy.html", "admin.html",
];

type Handler = (e: unknown) => void;

/** Pull initContextMenuGuard out of a page, run it, and return its listener. */
function loadGuard(page: string): Handler {
  const html = readFileSync(join(repoRoot, page), "utf8");
  const match = /^([ \t]*)function initContextMenuGuard\(\) \{/m.exec(html);
  assert.ok(match, `initContextMenuGuard not found in ${page}`);
  const indent = match[1];
  const start = match.index;
  const end = html.indexOf(`\n${indent}}`, start);
  assert.ok(end > start, `could not find the end of initContextMenuGuard in ${page}`);
  const src = html.slice(start, end + indent.length + 2);

  let captured: Handler | null = null;
  const doc = {
    addEventListener(type: string, fn: Handler) {
      assert.equal(type, "contextmenu", `${page}: guard listens for ${type}`);
      captured = fn;
    },
  };
  new Function("document", `${src}; return initContextMenuGuard;`)(doc)();
  assert.ok(captured, `${page}: guard registered no listener`);
  return captured as unknown as Handler;
}

/** A synthetic contextmenu event. `matches` is what target.closest() will find. */
function event(button: number, matches = false) {
  const state = { prevented: false };
  return {
    event: {
      button,
      target: { closest: (_sel: string) => (matches ? {} : null) },
      preventDefault() { state.prevented = true; },
    },
    state,
  };
}

for (const page of PAGES) {
  test(`${page}: a mouse right-click is suppressed`, () => {
    const guard = loadGuard(page);
    const { event: e, state } = event(2);
    guard(e);
    assert.equal(state.prevented, true);
  });

  test(`${page}: a keyboard-invoked menu is NOT suppressed`, () => {
    // Menu key / Shift+F10 report button 0. Blocking these takes the context
    // menu away from screen reader and keyboard-only users, which is a WCAG
    // problem shipped on the site that sells WCAG scanning.
    const guard = loadGuard(page);
    const { event: e, state } = event(0);
    guard(e);
    assert.equal(state.prevented, false);
  });

  test(`${page}: right-click inside a text field is NOT suppressed`, () => {
    const guard = loadGuard(page);
    const { event: e, state } = event(2, true);
    guard(e);
    assert.equal(state.prevented, false);
  });

  test(`${page}: a target with no closest() does not throw`, () => {
    const guard = loadGuard(page);
    let prevented = false;
    guard({ button: 2, target: null, preventDefault() { prevented = true; } });
    assert.equal(prevented, true, "a null target should still be suppressed, not crash");
  });

  test(`${page}: the guard is actually called on load`, () => {
    // A function nothing invokes is the failure mode that looks like it works
    // in review and does nothing in the browser.
    const html = readFileSync(join(repoRoot, page), "utf8");
    const calls = html.split("initContextMenuGuard();").length - 1;
    assert.equal(calls, 1, `expected exactly one initContextMenuGuard() call site in ${page}`);
  });

  test(`${page}: the code still says what it is not`, () => {
    // This assertion exists so the honest comment cannot be quietly deleted and
    // the guard later described to a client as source protection.
    const html = readFileSync(join(repoRoot, page), "utf8");
    assert.match(html, /does not protect this page's source/,
      `${page}: the comment stating this is not a security control was removed`);
  });
}

test("no page suppresses the menu on touch long-press", () => {
  // Long-press reports button 0, the same as the keyboard path. It is not a
  // right-click, and blocking it would break text selection and copy for every
  // phone user while stopping nobody from reading source.
  for (const page of PAGES) {
    const guard = loadGuard(page);
    const { event: e, state } = event(0);
    guard(e);
    assert.equal(state.prevented, false, `${page} blocks long-press`);
  }
});
