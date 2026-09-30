// support@ and security@ forward to a real inbox.
//
//   node --experimental-strip-types --test tests/email/inbound-mail.test.ts
//
// Until 2026-09-30 no Resend webhook pointed at this project, so mail to
// CavScope's published addresses reached no one -- including security@, the
// address security.txt tells a researcher to use. cavscope-inbound-mail
// forwards each message to cavscope.mail_routes' forward_to, Reply-To the
// sender. This runs the shipped pure half and pins the index's safety shape.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import {
  addressOf, recipients, addressedTo, isOwnDomain, usableTargets, buildForward, retryable, type Route,
} from "../../supabase/functions/cavscope-inbound-mail/core.ts";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const index = readFileSync(join(root, "supabase/functions/cavscope-inbound-mail/index.ts"), "utf8");
const migration = readFileSync(join(root, "supabase/migrations/20260930185418_inbound_mail_routes.sql"), "utf8");
const config = readFileSync(join(root, "supabase/config.toml"), "utf8");

const SEC: Route = {
  address: "security@mail.cavscope.28footsystems.com",
  forward_to: ["owner@example.com"],
  sender: "CavScope Security <security@mail.cavscope.28footsystems.com>",
  subject_tag: "[CavScope SECURITY]",
};

test("addresses parse from every shape Resend sends", () => {
  assert.equal(addressOf("Jane Doe <Jane@Example.com>"), "jane@example.com");
  assert.equal(addressOf({ address: "a@b.co" }), "a@b.co");
  assert.deepEqual(recipients(["x@y.co", "X@Y.co", "Z <z@y.co>"]), ["x@y.co", "z@y.co"]);
  assert.deepEqual(addressedTo({ to: ["support@mail.cavscope.28footsystems.com"], cc: "security@mail.muster.partners" }),
    ["support@mail.cavscope.28footsystems.com", "security@mail.muster.partners"]);
});

test("the forward goes to the route's inbox, reply-to the sender, tagged", () => {
  const body = buildForward({ route: SEC, from: "researcher@example.org", subject: "XSS on /signin",
    text: "details", html: "<p>details</p>", attachments: 0, bodyFetched: true });
  assert.deepEqual(body.to, ["owner@example.com"]);
  assert.equal(body.reply_to, "researcher@example.org");
  assert.equal(body.from, SEC.sender);
  assert.equal(body.subject, "[CavScope SECURITY] XSS on /signin");
  assert.match(String(body.text), /^From: researcher@example\.org\nTo: security@mail\.cavscope\.28footsystems\.com\n/);
  assert.match(String(body.html), /<p>details<\/p>$/);
});

test("a forward still goes out when the body or attachments cannot be carried, and says where to look", () => {
  const body = buildForward({ route: SEC, from: "r@example.org", subject: "", text: "", html: "", attachments: 2, bodyFetched: false });
  assert.equal(body.subject, "[CavScope SECURITY] (no subject)");
  assert.match(String(body.text), /2 attachments not forwarded/);
  assert.match(String(body.text), /body could not be read here/);
  assert.equal(body.html, undefined);
});

test("sender-controlled text cannot inject markup into the forward's header", () => {
  const body = buildForward({ route: SEC, from: "<script>@x.io", subject: "s", text: "", html: "<b>x</b>", attachments: 0, bodyFetched: true });
  assert.doesNotMatch(String(body.html).split("</div>")[0], /<script>/);
});

test("a forward is never sent to a CavScope mailbox, so it cannot loop", () => {
  assert.ok(isOwnDomain("support@mail.cavscope.28footsystems.com"));
  assert.ok(isOwnDomain("x@mail.muster.partners"));
  assert.deepEqual(usableTargets({ ...SEC, forward_to: ["support@mail.cavscope.28footsystems.com", "owner@example.com"] }), ["owner@example.com"]);
  assert.match(index, /if \(!from \|\| isOwnDomain\(from\)\) return json\(\{ ignored: "from a CavScope mailbox" \}\);/);
});

test("the endpoint fails closed and ignores other brands' mail", () => {
  assert.match(index, /if \(!secret\) return json\(\{ error: "webhook verification is not configured" \}, 503\);/);
  assert.ok(index.indexOf("verifySvixSignature(") < index.indexOf("JSON.parse(raw)"), "the body is parsed only after the signature verifies");
  assert.match(index, /if \(!to\.some\(isOwnDomain\)\) return json\(\{ ignored: "not a CavScope address" \}\);/);
  assert.ok(index.indexOf("ignored: \"not a CavScope address\"") < index.indexOf("receivedBody(emailId)"), "another brand's message body is never fetched");
});

test("a redelivery cannot send a second copy, and a failed send is retried", () => {
  assert.match(index, /cavscope_engine_claim_mail_forward/);
  assert.match(index, /"Idempotency-Key": `cavscope-inbound-\$\{emailId\}-\$\{route\.address\}`/);
  assert.ok(retryable(429) && retryable(503) && retryable(0) && !retryable(422));
  assert.match(index, /return json\(\{ forwarded: results \}, retry \? 502 : 200\);/);
});

test("the routing RPCs are service-role only, and no inbox is committed to the repo", () => {
  for (const fn of ["cavscope_engine_inbound_secret()", "cavscope_engine_mail_routes(text[])"]) {
    assert.match(migration, new RegExp(`revoke all on function public\\.${fn.replace(/[()[\]]/g, "\\$&")} from public, anon, authenticated;`));
  }
  assert.doesNotMatch(migration, /insert into cavscope\.mail_routes/i);
  assert.doesNotMatch(migration, /@28footmarketing\.com|@gmail\.com/);
  assert.match(config, /\[functions\.cavscope-inbound-mail\]\nverify_jwt = false|\[functions\.cavscope-inbound-mail\][\s\S]*?verify_jwt = false/);
});
