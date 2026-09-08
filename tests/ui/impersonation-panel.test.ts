// Renders the super admin console's impersonation panel from app.html with mock
// data and asserts what it produces.
//
//   node --experimental-strip-types --test tests/ui/impersonation-panel.test.ts
//
// The template is EXTRACTED FROM app.html rather than copied here, for the same
// reason the ai_narrative eval imports narrative.ts: a test holding its own copy
// of the markup passes forever while the page drifts away from it. If someone
// edits the panel, these assertions run against the edit.
//
// What this is for, above all, is escaping. Every field on this panel is
// attacker-influenced -- a target's email, an admin's typed reason -- and it is
// all interpolated into innerHTML. One missing escapeHtml() is stored XSS in a
// super admin's browser, which is the worst place in the product to have it.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");

const PANEL_START = '          <div class="panel" style="margin-bottom:24px; ${imp.active';
const PANEL_END = '          <div class="panel" style="margin-bottom:24px;">\n            <div class="panel-head"><div><h3>Users (${users.length})';

function extractPanelTemplate(): string {
  const html = readFileSync(join(repoRoot, "app.html"), "utf8");
  const start = html.indexOf(PANEL_START);
  const end = html.indexOf(PANEL_END);
  assert.notEqual(start, -1, "impersonation panel not found in app.html -- did its markup change?");
  assert.notEqual(end, -1, "users panel not found in app.html -- the extraction anchor moved");
  assert.ok(end > start, "panel anchors are out of order");
  return html.slice(start, end);
}

// app.html's own helper, reproduced only so the extracted template can run
// outside a browser. The assertions below check the template CALLS it, which is
// the property that matters.
const escapeHtml = (t: unknown) =>
  String(t ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

type Imp = Record<string, unknown>;
type User = { id: number; email: string; role: string };
type LogRow = Record<string, unknown>;

function render(imp: Imp, users: User[], impLog: LogRow[]): string {
  const tpl = extractPanelTemplate().replace(/this\.impLog/g, "self.impLog");
  const fn = new Function("imp", "users", "escapeHtml", "self", "return `" + tpl + "`;");
  return fn(imp, users, escapeHtml, { impLog }) as string;
}

const USERS: User[] = [
  { id: 7, email: "member@tenant.example", role: "user" },
  { id: 8, email: "peer-admin@28fs.example", role: "super_admin" },
];

const XSS = '<img src=x onerror=alert(1)>';

test("idle state offers the start form", () => {
  const h = render({ active: false }, USERS, []);
  assert.ok(h.includes("Live.startImpersonation"), "no start form");
  assert.ok(h.includes("impReason"), "no reason field");
  assert.ok(h.includes("impMinutes"), "no duration field");
  assert.ok(!h.includes("Live.endImpersonation"), "end button shown while idle");
});

test("super admins are absent from the target list", () => {
  // The database refuses them too (muster_038). This asserts the UI does not
  // dangle an option that can only ever produce an error.
  const h = render({ active: false }, USERS, []);
  assert.ok(h.includes("member@tenant.example"), "eligible user missing");
  assert.ok(!h.includes("peer-admin@28fs.example"), "a super admin was offered as a target");
});

test("active state shows the banner and hides the start form", () => {
  const h = render(
    { active: true, target_email: "member@tenant.example", target_user_id: 7, reason: "ticket 412", seconds_remaining: 900 },
    USERS, [],
  );
  assert.ok(h.includes("impCountdown"), "no countdown");
  assert.ok(h.includes("Live.endImpersonation"), "no end button");
  assert.ok(h.includes("impView"), "no impersonated view host");
  assert.ok(!h.includes("Live.startImpersonation"), "start form shown during an active session");
  assert.ok(h.includes("ticket 412"), "the reason is not displayed back to the admin");
});

test("the reason reaches the banner, because the tenant sees it too", () => {
  const h = render(
    { active: true, target_email: "a@b.co", target_user_id: 7, reason: "investigating a missing SITREP", seconds_remaining: 60 },
    USERS, [],
  );
  assert.ok(h.includes("investigating a missing SITREP"));
});

test("the audit log renders, and says empty when it is", () => {
  assert.ok(render({ active: false }, USERS, []).includes("No impersonation sessions"));

  const h = render({ active: false }, USERS, [{
    admin_email: "admin@28fs.example", target_email: "member@tenant.example",
    reason: "ticket 412", started_at: "2026-09-08T06:30:00Z", events: 3,
    active: false, ended_reason: "ended_by_admin",
  }]);
  assert.ok(h.includes("admin@28fs.example"), "admin missing from the log");
  assert.ok(h.includes("2026-09-08 06:30"), "timestamp not formatted");
  assert.ok(h.includes("ended_by_admin"), "outcome missing");
});

test("a live session is marked active in the log", () => {
  const h = render({ active: false }, USERS, [{
    admin_email: "a@b.co", target_email: "c@d.co", reason: "x", started_at: "2026-09-08T06:30:00Z",
    events: 1, active: true, ended_reason: null,
  }]);
  assert.ok(h.includes(">active<"), "an in-flight session does not read as active");
});

// The one that matters most.
//
// The property being asserted is that no payload can BECOME markup, not that
// suspicious substrings are absent. escapeHtml neutralises < > & and ", so
// `onerror=alert(1)` survives inside the escaped text and is inert -- it can
// never be an attribute, because the tag it would need was escaped away.
test("no attacker-influenced field can become markup, in either state", () => {
  const active = render(
    { active: true, target_email: XSS, target_user_id: 7, reason: XSS, seconds_remaining: 900 },
    USERS,
    [{ admin_email: XSS, target_email: XSS, reason: XSS, started_at: "2026-09-08T06:30:00Z", events: 1, active: true, ended_reason: XSS }],
  );
  const idle = render({ active: false }, [{ id: 9, email: XSS, role: "user" }], []);

  for (const [name, html] of [["active", active], ["idle", idle]] as const) {
    assert.ok(!html.includes("<img"), `${name}: a tag was formed from user input`);
    assert.ok(html.includes("&lt;img src=x"), `${name}: the payload was not escaped, it just vanished`);
  }
});

test("a quote in user input cannot break out of an attribute", () => {
  // escapeHtml does not escape the apostrophe, so this also documents the rule
  // the panel relies on: nothing attacker-influenced is interpolated into an
  // attribute here. Everything lands in text content.
  const payload = '" onmouseover="alert(1)';
  const html = render(
    { active: true, target_email: payload, target_user_id: 7, reason: payload, seconds_remaining: 60 },
    USERS, [],
  );
  assert.ok(!html.includes('" onmouseover='), "a raw double quote reached the output");
  assert.ok(html.includes("&quot; onmouseover=&quot;"), "the quote was not escaped");
});

test("the markup is balanced in both states", () => {
  for (const html of [
    render({ active: false }, USERS, []),
    render({ active: true, target_email: "a@b.co", target_user_id: 7, reason: "r", seconds_remaining: 10 }, USERS,
      [{ admin_email: "a", target_email: "b", reason: "c", started_at: "2026-09-08T06:30:00Z", events: 0, active: false, ended_reason: "expired" }]),
  ]) {
    const open = (html.match(/<div/g) ?? []).length;
    const close = (html.match(/<\/div>/g) ?? []).length;
    assert.equal(open, close, `unbalanced divs: ${open} open, ${close} close`);
  }
});

test("interactive elements carry tooltips, per the repo's standing rule", () => {
  const idle = render({ active: false }, USERS, []);
  const active = render({ active: true, target_email: "a@b.co", target_user_id: 7, reason: "r", seconds_remaining: 10 }, USERS, []);
  // Target select, reason, duration, submit. The log table header would add a
  // fifth, but this render has an empty log.
  assert.ok((idle.match(/data-tooltip/g) ?? []).length >= 4, "idle state is under-documented");
  // Banner, countdown, end button, view host.
  assert.ok((active.match(/data-tooltip/g) ?? []).length >= 4, "active state is under-documented");
});
