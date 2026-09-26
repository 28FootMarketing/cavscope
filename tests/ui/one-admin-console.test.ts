// There is one super admin console, admin.html at app.muster.partners/admin.
//
//   node --experimental-strip-types --test tests/ui/one-admin-console.test.ts
//
// Until 2026-09-23 there were two. app.html carried a "Platform Super Admin
// Console" view that owned every write -- plans, roles, incident triage,
// pricing, the flag registry, support impersonation, an ad-hoc URL runner --
// while admin.html read a different RPC, looked different, and owned the
// reports and the audit runner. They disagreed in ways nobody had checked:
// app.html's "platform-wide" white-label switch changed only local page state,
// its demo copy advertised a headless browser crawler the engine has never had,
// and admin.html read a missing pricing `visible` key as "shown" while the
// public page, correctly, showed Partner alone.
//
// This file keeps it at one. A platform RPC called from app.html again, or a
// write that exists in only one of the two places, fails here rather than in
// front of a super admin who has to work out which console is telling the truth.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const read = (p: string) => readFileSync(join(repoRoot, p), "utf8");
const app = read("app.html");
const admin = read("admin.html");

const adminRpcs = (html: string) => new Set([...html.matchAll(/'(muster_admin_[a-z_]+)'/g)].map((m) => m[1]));

// Every super admin write, and the reads that exist only to back one.
const CONSOLE_RPCS = [
  "muster_admin_console",
  "muster_admin_set_plan",
  "muster_admin_set_user_role",
  "muster_admin_update_incident",
  "muster_admin_set_pricing_stage",
  "muster_admin_set_pricing_visibility",
  "muster_admin_flag_registry",
  "muster_admin_set_flag",
  "muster_admin_kill_switch",
  "muster_admin_set_flag_plan_minimum",
  "muster_admin_clear_flag_override",
  "muster_admin_create_flag",
  "muster_admin_delete_flag",
  "muster_admin_impersonate_status",
  "muster_admin_impersonation_log",
  "muster_admin_impersonate_start",
  "muster_admin_impersonate_end",
  "muster_admin_impersonated_view",
  "muster_admin_run_url",
  "muster_admin_platform_extras",
  "muster_admin_sitreps",
  "muster_admin_sitrep",
];

test("admin.html calls every super admin RPC the console needs", () => {
  const used = adminRpcs(admin);
  for (const fn of CONSOLE_RPCS) assert.ok(used.has(fn), `${fn} is not called from admin.html`);
});

test("app.html calls no platform admin RPC except the one that opens a tenant", () => {
  // muster_admin_tenant is how a super admin enters a tenant's workspace, which
  // is app.html's job; admin.html links to it as /app#tenant=<id>.
  const used = [...adminRpcs(app)];
  assert.deepEqual(used, ["muster_admin_tenant"], `app.html still calls: ${used.join(", ")}`);
});

test("no other page calls a platform admin RPC", () => {
  const pages = readdirSync(repoRoot).filter((f) => f.endsWith(".html") && f !== "admin.html" && f !== "app.html");
  for (const page of pages) {
    const used = [...adminRpcs(read(page))];
    assert.deepEqual(used, [], `${page} calls ${used.join(", ")}; super admin work belongs in admin.html`);
  }
});

test("app.html has no super admin view left, only the tenant's own settings", () => {
  assert.doesNotMatch(app, /id="superadmin"/);
  assert.doesNotMatch(app, /data-view="superadmin"/);
  assert.doesNotMatch(app, /showView\('superadmin'\)/);
  assert.match(app, /<section id="teamSettings" class="view">/);
  assert.match(app, /data-view="teamSettings"/);
  // The team, API key and LLM panels a tenant manages for itself still land there.
  assert.match(app, /this\.panel\('liveAgentsPanel', 'teamSettings'\)/);
  assert.match(app, /this\.panel\('liveLlmPanel', 'teamSettings'\)/);
  // And the branding editor is still reachable, because it was only ever
  // reachable from inside the old view.
  assert.match(app, /id="btnConfigureWhiteLabel"[^>]*onclick="openModal\('whitelabel_settings'\)"/);
});

test("app.html's white-label switch is a sample-data preview, not a platform control", () => {
  // In live mode it used to be enabled for a super admin and flip nothing but
  // a local variable while claiming to be platform-wide.
  assert.match(app, /id="ffWhiteLabelDemoSwitch"/);
  assert.match(app, /const demoSwitch = document\.getElementById\('ffWhiteLabelDemoSwitch'\);\n\s*if \(demoSwitch\) demoSwitch\.hidden = true;/);
  assert.doesNotMatch(app, /toggle\.disabled = !this\.ws\.is_super_admin/);
  // .toggle-switch sets its own display, which beats the hidden attribute, so
  // without this rule the "hidden" preview switch stayed on screen in live mode.
  // Found by driving the page, not by reading it.
  assert.match(app, /\.toggle-switch\[hidden\] \{ display: none; \}/);
});

test("the headless-crawler claim is gone with the demo console", () => {
  // The engine is HTTP-native with no browser (CLAUDE.md, docs/SCAN-RULES.md).
  assert.doesNotMatch(app, /Headless Browser Crawler/i);
  assert.doesNotMatch(app, /Puppeteer\/Playwright/);
});

test("the links to the console are hidden until a super admin is confirmed", () => {
  for (const id of ["navPlatformConsole", "btnPlatformConsole"]) {
    const tag = app.slice(app.lastIndexOf("<", app.indexOf(`id="${id}"`)), app.indexOf(">", app.indexOf(`id="${id}"`)) + 1);
    assert.match(tag, /href="\/admin"/, `${id} must link to /admin`);
    assert.match(tag, /\shidden(\s|>)/, `${id} must ship hidden`);
    assert.match(tag, /data-tooltip="/, `${id} needs a tooltip`);
  }
  assert.match(app, /\['navPlatformConsole', 'btnPlatformConsole'\]\.forEach\(id => \{ const el = document\.getElementById\(id\); if \(el\) el\.hidden = !isSuper; \}\);/);
});

test("a super admin landing on /app goes to the console, but a fragment keeps them", () => {
  const lw = app.slice(app.indexOf("async loadWorkspace() {"), app.indexOf("tenantFromOrg(o) {"));
  assert.match(lw, /if \(!this\._landed\)/, "the fragment check must run once, not on every reload");
  assert.match(lw, /const m = this\.ws\.is_super_admin \? \/\^tenant=\(\\d\+\)\$\/\.exec\(hash\) : null;/);
  assert.match(lw, /\} else if \(this\.ws\.is_super_admin && !hash\) \{\n\s*location\.replace\(location\.origin \+ '\/admin'\);/);
  assert.match(lw, /await this\.openTenant\(pendingTenant\)/);
  // admin.html's two ways back into the app both carry a fragment, so neither
  // bounces straight back here.
  assert.match(admin, /href="\/app#tenant=\$\{Number\(o\.id\)\}"/);
  assert.match(admin, /class="strip-cta" href="\/app#overview"/);
});

test("an ordinary view fragment (from a transactional email CTA) opens that view once on load", () => {
  const lw = app.slice(app.indexOf("async loadWorkspace() {"), app.indexOf("tenantFromOrg(o) {"));
  assert.match(lw, /hash && \/\^\[a-z\]\+\$\/i\.test\(hash\) && document\.querySelector\(`#mainNav button\[data-view="\$\{hash\}"\]`\)/);
  assert.match(lw, /pendingView = hash;/);
  assert.match(lw, /else if \(pendingView\) showView\(pendingView\);/);
});

test("changes that reach other people ask first", () => {
  const writes = admin.slice(admin.indexOf("// ---- writes"), admin.indexOf("// Same set of shapes the SQL predicate"));
  for (const fn of ["setPlan", "setRole", "setPricingStage", "setFlagDefault", "killSwitch", "clearFlagOverride", "deleteFlag"]) {
    const body = writes.slice(writes.indexOf(`async function ${fn}(`), writes.indexOf("\n  }\n", writes.indexOf(`async function ${fn}(`)));
    assert.ok(body.length > 0, `${fn} not found`);
    assert.match(body, /window\.confirm\(/, `${fn} must confirm before writing`);
  }
});

test("a refused write snaps the control back to what the database says", () => {
  const w = admin.slice(admin.indexOf("async function write("), admin.indexOf("// The handlers the controls above call."));
  assert.match(w, /if \(error\) \{\n\s*flash\('bad', writeError\(error\)\);\n\s*await refresh\(false\);/);
  assert.match(w, /await refresh\(true\);/);
});

test("every write control carries a tooltip", () => {
  const direct = ["plan", "role", "incident", "stage", "flag-plan", "override-revoke", "flag-delete", "imp-end"];
  for (const kind of direct) {
    let i = admin.indexOf(`data-act="${kind}"`);
    assert.ok(i > 0, `no control with data-act="${kind}"`);
    for (; i > 0; i = admin.indexOf(`data-act="${kind}"`, i + 1)) {
      const tag = admin.slice(admin.lastIndexOf("<", i), admin.indexOf(">", admin.indexOf("data-tooltip", i)) + 1);
      assert.ok(tag.includes("data-tooltip"), `data-act="${kind}" needs a data-tooltip on its own tag`);
    }
  }
  // A switch's checkbox is visually hidden; the tooltip sits on its label.
  for (const kind of ["tier-visible", "flag-default", "flag-kill"]) {
    const i = admin.indexOf(`data-act="${kind}"`);
    assert.ok(i > 0, `no control with data-act="${kind}"`);
    const label = admin.slice(admin.lastIndexOf('<label class="switch"', i), i);
    assert.match(label, /data-tooltip="/, `the switch for ${kind} needs a tooltip`);
  }
});

test("side reads fail per panel, not per page", () => {
  const side = admin.slice(admin.indexOf("// ---- side reads"), admin.indexOf("// ---- writes"));
  assert.match(side, /\.then\(\(r\) => r, \(err\) => \(\{ error: err \}\)\)/);
  for (const k of ["registry", "imp", "impLog", "overview", "platform"]) assert.match(side, new RegExp(`\\b${k}: \\['muster_admin_`));
});

test("the flag forms keep what was typed across a re-render, and across a refused save", () => {
  // render() replaces the page on a search keystroke, a filter change, a save
  // and a countdown expiry. These forms held their values only in the DOM until
  // 2026-09-23, so any of those blanked them, and a refused create (a duplicate
  // key) came back empty.
  const reg = admin.slice(admin.indexOf("const drafts = {};"), admin.indexOf("// Surfaces the design calls for"));
  for (const field of ["reason", "expires"]) assert.match(reg, new RegExp(`name="${field}"[^>]*value="\\$\\{escapeHtml\\(od\\.${field} \\|\\| ''\\)\\}"`), `override ${field} must render from its draft`);
  for (const field of ["key", "name", "description"]) assert.match(reg, new RegExp(`name="${field}"[^>]*value="\\$\\{escapeHtml\\(cd\\.${field} \\|\\| ''\\)\\}"`), `new-flag ${field} must render from its draft`);
  assert.match(reg, /selectedIf\(od\.org, t\.id\)/);
  assert.match(reg, /selectedIf\(cd\.scope, sc\)/);
  assert.match(reg, /name="default_enabled" aria-label="Default on"\$\{cd\.default_enabled \? ' checked' : ''\}/);
  assert.match(reg, /data-flag="__new"\$\{openFlags\.has\('__new'\) \? ' open' : ''\}/);

  // A draft is dropped only when its save succeeded; write() returns null on a refusal.
  const writes = admin.slice(admin.indexOf("async function addFlagOverride("), admin.indexOf("async function deleteFlag("));
  assert.match(writes, /if \(saved\) \{ delete drafts\['override:' \+ key\]; render\(\); \}/);
  assert.match(writes, /if \(saved\) \{ delete drafts\.create; render\(\); \}/);

  // Recording a keystroke must not re-render, which would move the caret.
  const rec = admin.slice(admin.indexOf("function recordDraft(el) {"), admin.indexOf("// `toggle` does not bubble"));
  assert.ok(rec.length > 0, "recordDraft not found");
  assert.doesNotMatch(rec, /render\(\)/);
  const events = admin.slice(admin.indexOf("// ---- events"), admin.indexOf("// Right-click context menu suppression"));
  assert.equal((events.match(/recordDraft\(e\.target\);/g) || []).length, 2, "record from both input and change");
});
