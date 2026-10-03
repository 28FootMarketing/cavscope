// The support widget: one source, identical in both pages, on the right edge, not an email link.
//
//   node --experimental-strip-types --test tests/support/widget.test.ts

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { PAGES, START, END, source } from "../../tools/support/sync.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const read = (p: string) => readFileSync(join(root, p), "utf8");
const src = source();

test("every page carries a copy identical to tools/support/widget.html", () => {
  for (const page of PAGES) {
    const t = read(page);
    const a = t.indexOf(START), b = t.indexOf(END);
    assert.ok(a > 0 && b > a, `${page} has the markers`);
    assert.equal(t.slice(a + START.length, b).trim(), src, `${page} drifted; run node tools/support/sync.mjs`);
    assert.equal(t.split(START).length, 2, `${page} has exactly one copy`);
  }
});

test("the workspace and the console both have it", () => {
  assert.deepEqual([...PAGES].sort(), ["admin.html", "app.html"]);
});

test("the tab sits on the right edge, vertically centred", () => {
  const css = /\.cs-support-tab \{([^}]*)\}/.exec(src)![1];
  assert.match(css, /right:\s*0/);
  assert.match(css, /top:\s*50%/);
  assert.match(css, /translateY\(-50%\)/);
});

test("support is a form with a message, a category list and a screenshot, not a mailto link", () => {
  assert.ok(!/mailto:/.test(src));
  for (const page of PAGES) assert.ok(!/mailto:support/.test(read(page)), `${page} has no support email link`);
  for (const id of ["csSupportMessage", "csSupportCategory", "csSupportShotOn", "csSupportShotImg"]) assert.match(src, new RegExp(`id="${id}"`));
  assert.match(src, /<select id="csSupportCategory"/, "category is a pick-list, not typed");
});

test("the screenshot tool is pinned by integrity hash on an origin the CSP already allows", () => {
  assert.match(src, /html2canvas@1\.4\.1/);
  assert.match(src, /sha384-[A-Za-z0-9+/=]{64}/);
  assert.match(src, /integrity = H2C_SRI/);
  const mw = read("middleware.js");
  assert.match(mw, /script-src[^"]*https:\/\/cdn\.jsdelivr\.net/);
});

test("password fields are blanked in the capture and the widget is left out of its own picture", () => {
  assert.match(src, /input\[type="password"\][\s\S]{0,80}value = ''/);
  assert.match(src, /el\.id === 'csSupportTab' \|\| el\.id === 'csSupportPanel'/);
});

test("it never prints, closes on Escape and returns focus to the tab", () => {
  assert.match(src, /@media print \{[^}]*display: none !important/);
  assert.match(src, /e\.key === 'Escape'/);
  assert.match(src, /csSupportTab'\)\.focus\(\)/);
});

test("it asks to sign in rather than failing silently when signed out", () => {
  assert.match(src, /csSupportSignedOut/);
  assert.match(src, /href="\/signin"/);
});

test("every interactive element carries a tooltip, and non-interactive ones are focusable", () => {
  for (const id of ["csSupportTab", "csSupportCategory", "csSupportMessage", "csSupportShotOn", "csSupportRetake", "csSupportCancel", "csSupportSend"]) {
    assert.match(src, new RegExp(`id="${id}"[^>]*data-tooltip=`), `${id} has a tooltip`);
  }
  assert.match(src, /<h2 id="csSupportTitle" tabindex="0" data-tooltip=/);
});

test("both pages hand the widget their own client; it posts to the function that exists", () => {
  for (const page of PAGES) assert.match(read(page), /window\.CavSupportConfig = \{\s*getClient:/);
  assert.match(src, /functions\/v1\/cavscope-support-request/);
  assert.ok(readdirSync(join(root, "supabase", "functions")).includes("cavscope-support-request"));
  assert.match(read("supabase/config.toml"), /\[functions\.cavscope-support-request\][\s\S]*?verify_jwt = true/);
});

test("the function files the request under the caller's JWT and sends the email from the service role only after", () => {
  const fn = read("supabase/functions/cavscope-support-request/index.ts");
  assert.ok(fn.indexOf('"cavscope_submit_support_request"') < fn.indexOf('"cavscope_engine_mail_routes"'));
  assert.match(fn, /global: \{ headers: \{ Authorization: auth \} \}/);
  assert.ok(!/storage/i.test(fn.replace(/\/\/.*$/gm, "")), "the screenshot is not stored");
});

test("the database side: authenticated only for filing, service_role only for finishing", () => {
  const dir = join(root, "supabase", "migrations");
  const sql = readdirSync(dir).filter((f) => f.includes("support_request")).map((f) => readFileSync(join(dir, f), "utf8")).join("\n");
  assert.match(sql, /revoke all on function public\.cavscope_submit_support_request\([^)]*\) from public, anon;/);
  assert.match(sql, /grant execute on function public\.cavscope_submit_support_request\([^)]*\) to authenticated;/);
  assert.match(sql, /revoke all on function public\.cavscope_engine_finish_support_request\([^)]*\) from public, anon, authenticated;/);
  assert.match(sql, /revoke all on cavscope\.support_requests from public, anon, authenticated;/);
  assert.match(sql, /enable row level security/);
});
