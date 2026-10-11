// Every modal in the workspace is a dialog: it says so, has a name, takes focus, keeps Tab inside, closes
// on Escape, and its form fields are named. Found 2026-10-11 by opening all 25 in tools/site-axe/app.mjs:
// none had a dialog role, focus stayed behind them, Escape did nothing, 30 form fields in the record forms
// had no label association, the sign-in link was #0000ee on dark (1.8:1) and the onboarding advisory skipped
// from h3 to h5.
//
//   node --experimental-strip-types --test tests/ui/app-dialogs.test.ts

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const html = readFileSync(join(dirname(fileURLToPath(import.meta.url)), "..", "..", "app.html"), "utf8");

const BACKDROPS = ["modalBackdrop", "liveAuthBackdrop", "liveOnboardBackdrop", "scoreExplainerBackdrop"];

test("each modal dialog has a role, aria-modal and a name that points at its heading", () => {
  for (const id of BACKDROPS) {
    const at = html.indexOf(`id="${id}"`);
    assert.ok(at > 0, `${id} missing`);
    const dlg = html.slice(at, at + 400).match(/<div class="modal-dialog[^>]*>/)?.[0] ?? "";
    assert.match(dlg, /role="dialog"/, `${id}: role`);
    assert.match(dlg, /aria-modal="true"/, `${id}: aria-modal`);
    const target = dlg.match(/aria-labelledby="([^"]+)"/)?.[1];
    assert.ok(target, `${id}: aria-labelledby`);
    assert.match(html, new RegExp(`<h3[^>]*id="${target}"`), `${id}: heading #${target}`);
  }
});

test("focus, Tab and Escape are handled for every modal, by the function its Close button calls", () => {
  assert.match(html, /initTooltips\(\); initAccordions\(\); initContextMenuGuard\(\); initModalA11y\(\);/);
  for (const [id, fn] of [["modalBackdrop", "closeModal()"], ["liveAuthBackdrop", "Live.closeAuth()"], ["liveOnboardBackdrop", "Live.closeOnboard()"], ["scoreExplainerBackdrop", "closeScoreExplainer()"]])
    assert.ok(html.includes(`${id}: function () { ${fn}; }`), `${id} -> ${fn}`);
  assert.match(html, /e\.key === 'Escape'/);
  assert.match(html, /e\.key !== 'Tab'/);
});

test("record-form fields are tied to their labels after the form is drawn", () => {
  assert.match(html, /linkFormLabels\(document\.getElementById\('modalFormFields'\)\);\s*document\.getElementById\('modalBackdrop'\)\.classList\.add\('open'\)/);
});

test("modal links are readable and the advisory heading does not skip a level", () => {
  assert.match(html, /\.modal-dialog p\.modal-desc a \{ color: var\(--teal\)/);
  assert.doesNotMatch(html, /<h5[ >]/);
});
