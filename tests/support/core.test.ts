// The pure half of cavscope-support-request: what it accepts, what it refuses, the email it builds.
//
//   node --experimental-strip-types --test tests/support/core.test.ts

import { test } from "node:test";
import assert from "node:assert/strict";
import { validate, decodeScreenshot, buildEmail, esc, MAX_MESSAGE } from "../../supabase/functions/cavscope-support-request/core.ts";

const JPEG = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3]).toString("base64");
const PNG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 1, 2, 3]).toString("base64");
const ok = { category: "broken", message: "The risk register is empty" };

test("a plain message validates and trims", () => {
  const r = validate({ ...ok, message: "  hello  " });
  assert.ok(r.ok && r.value.message === "hello" && r.value.screenshot === null);
});

test("the category is a fixed list", () => {
  assert.equal(validate({ ...ok, category: "invoice" }).ok, false);
  assert.equal(validate({ message: "x" }).ok, false);
});

test("an empty or oversized message is refused", () => {
  assert.equal(validate({ ...ok, message: "   " }).ok, false);
  assert.equal(validate({ ...ok, message: "a".repeat(MAX_MESSAGE + 1) }).ok, false);
  assert.equal(validate({ ...ok, message: "a".repeat(MAX_MESSAGE) }).ok, true);
});

test("a screenshot must be a real JPEG or PNG, whatever its label says", () => {
  assert.ok(decodeScreenshot(`data:image/jpeg;base64,${JPEG}`) !== "invalid");
  assert.ok(decodeScreenshot(`data:image/png;base64,${PNG}`) !== "invalid");
  assert.equal(decodeScreenshot(`data:image/png;base64,${JPEG}`), "invalid", "a JPEG labelled PNG");
  assert.equal(decodeScreenshot(`data:text/html;base64,${JPEG}`), "invalid");
  assert.equal(decodeScreenshot("data:image/png;base64,!!!"), "invalid");
  assert.equal(decodeScreenshot("https://example.com/x.png"), "invalid");
  assert.equal(decodeScreenshot(null), null);
  assert.equal(decodeScreenshot(""), null);
});

test("an oversized screenshot is refused before it is decoded", () => {
  const big = Buffer.alloc(3_100_000, 1);
  big[0] = 0xff; big[1] = 0xd8; big[2] = 0xff;
  assert.equal(decodeScreenshot(`data:image/jpeg;base64,${big.toString("base64")}`), "invalid");
});

test("a bad screenshot fails the request rather than being dropped silently", () => {
  const r = validate({ ...ok, screenshot: "data:image/png;base64,AAAA" });
  assert.equal(r.ok, false);
});

test("organization id is kept only when it is a positive whole number", () => {
  assert.equal((validate({ ...ok, organization_id: 7 }) as any).value.organizationId, 7);
  assert.equal((validate({ ...ok, organization_id: "x" }) as any).value.organizationId, null);
  assert.equal((validate({ ...ok, organization_id: -3 }) as any).value.organizationId, null);
});

const route = { address: "support@mail.cavscope.28footsystems.com", forward_to: ["owner@example.com"], sender: "CavScope Support <support@mail.cavscope.28footsystems.com>", subject_tag: "[CavScope support]" };

test("the email replies to the person, escapes their words and attaches the screenshot", () => {
  const v = (validate({ ...ok, message: "<script>alert(1)</script>\nsecond line", page_url: "https://x/app", screenshot: `data:image/jpeg;base64,${JPEG}` }) as any).value;
  const p: any = buildEmail({ id: 42, route, from: "customer@example.com", v });
  assert.equal(p.reply_to, "customer@example.com");
  assert.deepEqual(p.to, ["owner@example.com"]);
  assert.match(p.subject, /^\[CavScope support\] #42 Something is broken: /);
  assert.ok(!/[\r\n]/.test(p.subject), "no header injection through the subject");
  assert.ok(!p.html.includes("<script>"), "message is escaped in the html");
  assert.match(p.html, /&lt;script&gt;/);
  assert.equal(p.attachments[0].filename, "screenshot-42.jpg");
  assert.equal(p.attachments[0].content, JPEG);
});

test("no screenshot means no attachment", () => {
  const v = (validate(ok) as any).value;
  assert.equal((buildEmail({ id: 1, route, from: "a@b.co", v }) as any).attachments, undefined);
});

test("esc covers the five characters that matter", () => {
  assert.equal(esc(`<a href="x">'&`), "&lt;a href=&quot;x&quot;&gt;&#39;&amp;");
});
