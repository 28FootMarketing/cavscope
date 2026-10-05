// The site's own accessibility fixes, pinned. They came from running the browser engine over the pages
// (tools/site-axe/run.mjs): axe found 5 issues and 23 contrast failures on the landing page alone.
//
//   node --experimental-strip-types --test tests/ui/site-accessibility.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
// @ts-ignore
import * as c from "../../workers/browser-scan/lib/contrast.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const read = (p: string) => readFileSync(join(root, p), "utf8");
const PAGES = ["index.html", "signin.html", "onboarding.html", "sitrep.html", "sitrep-sample.html", "privacy.html", "app.html", "admin.html", "beta.html", "html-audit.html"];
const tokens = read("assets/tokens.css");
const token = (name: string) => new RegExp(`--${name}:\\s*(#[0-9a-fA-F]{6})`).exec(tokens)![1];
const ratio = (a: string, b: string) => c.contrastRatio(c.parseColor(a), c.parseColor(b));

// Every dark surface text sits on, darkest to lightest.
const SURFACES = ["bg", "surface", "surface-card", "surface-elevated", "surface-raised", "surface-hover"].map(token);

test("the small-text colours clear 4.5:1 on every dark surface they are used on", () => {
  for (const t of ["text-muted", "text-dim", "rose-text", "teal", "amber"]) {
    for (const bg of SURFACES) assert.ok(ratio(token(t), bg) >= 4.5, `--${t} ${token(t)} on ${bg} is ${ratio(token(t), bg).toFixed(2)}:1`);
  }
});

test("--text-dim was 2.5 to 3.9:1 and is not that colour again", () => {
  assert.notEqual(token("text-dim").toLowerCase(), "#5d708e");
  for (const f of PAGES) assert.ok(!/#5d708e/i.test(read(f)), `${f} still carries the old --text-dim`);
});

test("red text uses --rose-text; --rose stays for fills", () => {
  for (const f of ["sitrep.html", "sitrep-sample.html"]) {
    const s = read(f);
    assert.match(s, /return 'var\(--rose-text\)'/, f);
    assert.match(s, /\.sev-critical, \.sev-high \{[^}]*color: var\(--rose-text\)/, f);
  }
});

test("every page's tooltip is hidden until it has text: an empty role=tooltip node fails axe on every page", () => {
  for (const f of PAGES) {
    const s = read(f);
    if (!s.includes("initTooltips")) continue;
    assert.match(s, /tip\.hidden = true;\s*\n\s*document\.body\.appendChild\(tip\)|tip\.hidden = true;\s*document\.body\.appendChild\(tip\)/, `${f}: starts hidden`);
    assert.match(s, /tip\.textContent = text;[\s\S]{0,120}?tip\.hidden = false;/, `${f}: unhidden when it shows`);
    assert.match(s, /tip\.classList\.remove\('show'\);\s*tip\.hidden = true;/, `${f}: hidden again on hide`);
  }
});

test("each public page has exactly one main landmark, a real header, and nothing in a bare div as its page body", () => {
  for (const f of ["index.html", "signin.html", "onboarding.html", "sitrep.html", "sitrep-sample.html", "privacy.html"]) {
    const s = read(f);
    assert.equal((s.match(/<main[\s>]/g) ?? []).length, 1, `${f}: one <main>`);
    assert.equal((s.match(/<\/main>/g) ?? []).length, 1, `${f}: closed`);
    assert.match(s, /<main[^>]*id="main"/, f);
  }
  for (const f of ["signin.html", "onboarding.html", "sitrep.html", "sitrep-sample.html", "index.html"]) {
    assert.match(read(f), /<header class="(topbar|statusbar)"/, `${f}: the top bar is a <header>`);
  }
});

test("the workspace: dropdowns have names, no button contains buttons, heading order holds, the toast is a status", () => {
  const s = read("app.html");
  for (const id of ["presetSelect", "topbarTenantSelect", "clientUrlQuickPick"])
    assert.match(s, new RegExp(`<select id="${id}"[^>]*aria-label="[^"]+"`), `${id} has an accessible name`);
  assert.ok(!/class="card metric-card"[^>]*role="button"/.test(s), "a metric card is not a role=button (it holds real buttons)");
  assert.equal((s.match(/class="card metric-card" style="cursor: pointer;" onclick="navigateCard/g) ?? []).length, 4, "the four cards still open their views for a pointer");
  for (const id of ["kpiEvidenceLabel"]) assert.match(s, new RegExp(`<label id="${id}" tabindex="0" data-tooltip=`), "the card's tooltip stays reachable by keyboard, on its label");
  assert.match(s, /<h3 role="heading" aria-level="2"[^>]*>One URL to Run It All/);
  assert.match(s, /<div class="toast" id="toast" role="status" aria-live="polite">/);
});

test("the avatar's white initials clear 4.5:1 across their whole gradient", () => {
  const m = /\.user-avatar \{[\s\S]*?background: linear-gradient\(135deg, (#[0-9a-f]{6}), (#[0-9a-f]{6})\)/i.exec(read("app.html"))!;
  for (const stop of [m[1], m[2]]) assert.ok(ratio("#ffffff", stop) >= 4.5, `${stop}: ${ratio("#ffffff", stop).toFixed(2)}:1`);
});
