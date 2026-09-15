// The forced-password-change gate: the edge function's policy, and the three
// places the same predicate is written.
//
//   node --experimental-strip-types --test tests/auth/set-password.test.ts
//
// Context. app_metadata.force_password_change was set on a live super-admin
// account at provisioning and nothing read it anywhere: not a page, not a
// policy, not a function. The account signed in on the old password and went
// straight to the workspace, while the account list said a change was required.
//
// The enforcement is muster.password_change_required() in Postgres (migration
// 20260915230805), which gates the authorization spine. That part cannot be
// tested from here -- it is verified against the live database, and the results
// are recorded in that migration's header. What IS testable here, and is where
// this will actually break, is the three-way agreement: Postgres, the edge
// function, and two browser pages each decide independently whether a claim
// means "required". If they drift, the gate either locks out someone it should
// not or waves through someone it should not, and both failures are silent.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  changeRequired,
  clearedAppMetadata,
  MAX_PASSWORD_BYTES,
  MIN_PASSWORD_CHARS,
  validateNewPassword,
} from "../../supabase/functions/muster-set-password/core.ts";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const read = (p: string) => readFileSync(join(ROOT, p), "utf8");

const EMAIL = "admin@anthonywashingtonsr.com";

// ---------------------------------------------------------------------------
// The predicate, in all three languages
// ---------------------------------------------------------------------------

// Provisioning tools write this flag both ways. The live account carries a JSON
// boolean in raw_app_meta_data and it arrives in the JWT as a boolean, but an
// admin setting it by hand from the dashboard writes the string. A check that
// catches one shape and not the other is not a check.
const CLAIM_SHAPES: Array<[string, unknown, boolean]> = [
  ["JSON boolean true", true, true],
  ["string \"true\"", "true", true],
  ["string \"True\"", "True", true],
  ["string \"t\"", "t", true],
  ["string \"1\"", "1", true],
  ["number 1", 1, true],
  ["JSON boolean false", false, false],
  ["string \"false\"", "false", false],
  ["number 0", 0, false],
  ["null", null, false],
  ["undefined (key absent)", undefined, false],
];

test("changeRequired agrees on every claim shape provisioning can write", () => {
  for (const [label, value, expected] of CLAIM_SHAPES) {
    const meta = value === undefined ? { provider: "email" } : { provider: "email", force_password_change: value };
    assert.equal(changeRequired(meta), expected, `${label} should be ${expected}`);
  }
  assert.equal(changeRequired(null), false, "no app_metadata at all is not a required change");
  assert.equal(changeRequired(undefined), false);
  assert.equal(changeRequired({}), false);
});

test("the SQL predicate accepts the same truthy set as the TypeScript one", () => {
  // The migration compares the ->> text against a literal list. If someone
  // widens or narrows one side without the other, the browser and the database
  // disagree about who is locked out.
  const sql = read("supabase/migrations/20260915230805_muster_052_force_password_change_gate.sql");
  assert.match(sql, /in \('true', 't', '1'\)/, "the SQL truthy set changed");
  // Not ::boolean. app_metadata is service-role-writable, and a cast error
  // inside this predicate would raise inside every RLS policy on the database.
  // Comments are stripped first, because the body says "Deliberately not
  // ::boolean" and a naive search matches its own warning.
  const body = sql
    .slice(sql.indexOf("function muster.password_change_required"), sql.indexOf("comment on function"))
    .split("\n")
    .filter((line) => !line.trim().startsWith("--"))
    .join("\n");
  assert.doesNotMatch(
    body,
    /::boolean/,
    "the predicate must not cast to boolean; an unrecognised value has to read as 'not required'",
  );
});

test("both browser pages test the same truthy set", () => {
  for (const page of ["signin.html", "app.html"]) {
    const html = read(page);
    assert.match(html, /\['true', 't', '1'\]\.includes\(v\.toLowerCase\(\)\)/,
      `${page} does not use the shared truthy set`);
    assert.match(html, /if \(v === true\) return true;/, `${page} does not accept a JSON boolean`);
  }
});

// ---------------------------------------------------------------------------
// Password policy
// ---------------------------------------------------------------------------

test("a reasonable passphrase is accepted", () => {
  for (const pw of ["correct horse battery", "Tuesday-Rain-Ledger-99", "a".repeat(MIN_PASSWORD_CHARS)]) {
    assert.deepEqual(validateNewPassword(pw, EMAIL), { ok: true }, `${pw} should pass`);
  }
});

test("shorter than the minimum is refused, and the message says the number", () => {
  const v = validateNewPassword("a".repeat(MIN_PASSWORD_CHARS - 1), EMAIL);
  assert.equal(v.ok, false);
  assert.equal(v.ok === false && v.reason, "too_short");
  assert.match(v.ok === false ? v.message : "", new RegExp(String(MIN_PASSWORD_CHARS)));
});

test("length counts characters, not UTF-16 code units", () => {
  // Twelve emoji is twelve characters to the person typing them and 24 to
  // .length. Counting code units would let a 6-character password through.
  const twelveEmoji = "😀".repeat(12);
  assert.equal([...twelveEmoji].length, 12);
  assert.equal(twelveEmoji.length, 24);
  assert.deepEqual(validateNewPassword(twelveEmoji, EMAIL), { ok: true });

  const sixEmoji = "😀".repeat(6);
  assert.equal(sixEmoji.length, 12, "this is exactly the value a code-unit count would wave through");
  assert.equal(validateNewPassword(sixEmoji, EMAIL).ok, false);
});

test("past the bcrypt ceiling is refused rather than silently truncated", () => {
  // GoTrue hashes with bcrypt, which uses the first 72 BYTES and discards the
  // rest without telling anyone. Accepting a 100-character passphrase and
  // storing 72 bytes of it is a lie the user cannot detect.
  const tooLong = "a".repeat(MAX_PASSWORD_BYTES + 1);
  const v = validateNewPassword(tooLong, EMAIL);
  assert.equal(v.ok, false);
  assert.equal(v.ok === false && v.reason, "too_long");

  // Bytes, not characters: 25 three-byte characters is 75 bytes.
  const multibyte = "日".repeat(25);
  assert.equal([...multibyte].length, 25, "well under the character minimum's concern");
  assert.equal(validateNewPassword(multibyte, EMAIL).ok, false, "75 bytes must be refused");
});

test("a leading or trailing space is refused", () => {
  // It survives the paste into this form and then does not survive the next
  // sign-in, because the sign-in form trims the email but the password field
  // does not get the same treatment everywhere. A password that works exactly
  // once is worse than a refusal.
  for (const pw of [" correct horse battery", "correct horse battery ", "\tcorrect horse battery"]) {
    const v = validateNewPassword(pw, EMAIL);
    assert.equal(v.ok, false, `${JSON.stringify(pw)} should be refused`);
    assert.equal(v.ok === false && v.reason, "whitespace_edges");
  }
  // But a space INSIDE is the whole point of a passphrase.
  assert.deepEqual(validateNewPassword("correct horse battery staple", EMAIL), { ok: true });
});

test("the most-guessed values are refused even when padded up to the minimum", () => {
  // REGRESSION, found by this test's first draft: almost every entry in the
  // blocklist is shorter than the 12-character minimum, so a bare membership
  // test could never fire -- "password" is refused as too short long before
  // anything looks it up. The list was decoration. What people actually submit
  // when a minimum forces them longer is the same word with padding, and the
  // padding costs an attacker nothing.
  for (const pw of [
    "password1234",     // padded to exactly the minimum
    "Password123456",   // padded and capitalised
    "changeme12345",
    "welcome123456",
    "administrator",    // long enough on its own
    "musterpassword",
    "!!!qwerty!!!!",    // padded on both ends
  ]) {
    const v = validateNewPassword(pw, EMAIL);
    assert.equal(v.ok, false, `${pw} should be refused`);
    assert.equal(v.ok === false && v.reason, "obvious", `${pw} refused for the wrong reason`);
  }
});

test("stripping padding does not block unrelated passphrases", () => {
  // The stem check is the kind of rule that over-fires if it is careless.
  for (const pw of [
    "correct horse battery",
    "Tuesday-Rain-Ledger-99",
    "passwords are not this",  // contains 'password' but is not it
    "9-lives-of-a-ledger",
    "adminstrative review 7",
  ]) {
    assert.deepEqual(validateNewPassword(pw, EMAIL), { ok: true }, `${pw} should be accepted`);
  }
});

test("the password cannot be the email or its local part", () => {
  for (const pw of [EMAIL, EMAIL.toUpperCase(), "admin@anthonywashingtonsr.com"]) {
    const v = validateNewPassword(pw, EMAIL);
    assert.equal(v.ok, false);
    assert.equal(v.ok === false && v.reason, "is_email");
  }
  // The local part here is "admin", which is below the minimum anyway, so use
  // an address whose local part is long enough to reach the check.
  const longLocal = "verylonglocalpart@example.com";
  const v = validateNewPassword("verylonglocalpart", longLocal);
  assert.equal(v.ok, false);
  assert.equal(v.ok === false && v.reason, "is_email");
});

test("a non-string, empty or missing password is refused before anything else", () => {
  for (const pw of [undefined, null, 12345678901234, {}, [], ""]) {
    const v = validateNewPassword(pw, EMAIL);
    assert.equal(v.ok, false, `${JSON.stringify(pw)} should be refused`);
    assert.equal(v.ok === false && v.reason, "missing");
  }
});

test("there are no composition rules", () => {
  // Deliberate, and worth a test so nobody "hardens" it back. Mandatory
  // symbol/digit/case rules push people to Password1! -- a shape every cracking
  // rule set expands for free -- and block the passphrases that actually
  // resist a search. NIST SP 800-63B: length and screening, not composition.
  assert.deepEqual(validateNewPassword("aaaaaaaaaaaaaaaa", EMAIL), { ok: true },
    "lower case only, no digits, no symbols: still accepted");
});

// ---------------------------------------------------------------------------
// The metadata merge
// ---------------------------------------------------------------------------

test("clearing the flag preserves the rest of app_metadata", () => {
  // provider and providers live in the same bag and GoTrue uses them to decide
  // which sign-in methods the account has. Replacing rather than merging would
  // be a much worse bug than the one this whole change fixes.
  const now = "2026-09-15T23:30:00.000Z";
  const out = clearedAppMetadata(
    { provider: "email", providers: ["email"], force_password_change: true },
    now,
  );
  assert.equal(out.provider, "email");
  assert.deepEqual(out.providers, ["email"]);
  assert.equal(out.force_password_change, false);
  assert.equal(out.force_password_change_cleared_at, now);
  assert.equal(changeRequired(out), false, "the cleared metadata must not still read as required");
});

test("clearing sets false rather than deleting the key", () => {
  // A deleted key and a key that was never set are indistinguishable
  // afterwards. Keeping false plus a timestamp is what makes the record
  // readable a year later.
  const out = clearedAppMetadata({ force_password_change: true }, "2026-09-15T23:30:00.000Z");
  assert.ok("force_password_change" in out);
  assert.equal(out.force_password_change, false);
});

test("clearing survives absent or malformed existing metadata", () => {
  for (const existing of [null, undefined, {}]) {
    const out = clearedAppMetadata(existing as Record<string, unknown> | null, "2026-09-15T23:30:00.000Z");
    assert.equal(out.force_password_change, false);
  }
});

// ---------------------------------------------------------------------------
// Wiring the pages cannot get wrong without this failing
// ---------------------------------------------------------------------------

test("signin.html checks the flag before it bounces a session to the workspace", () => {
  // Order is the whole thing. app.html sends a flagged session here; if this
  // page bounced it onward before checking, the two would ping-pong forever on
  // a page holding live credentials.
  const html = read("signin.html");
  const script = html.slice(html.indexOf("<script>"));
  const forcedCheck = script.indexOf("if (session && isForced(session)) { showForcedChange(); return; }");
  const bounce = script.indexOf("if (session) { window.location.href = WORKSPACE_URL; return; }");
  assert.notEqual(forcedCheck, -1, "signin.html does not check for a forced change in onAuthStateChange");
  assert.notEqual(bounce, -1, "the workspace bounce moved; re-check the ordering by hand");
  assert.ok(forcedCheck < bounce, "the forced-change check must come BEFORE the workspace bounce");
});

test("app.html hands a flagged session to the sign-in page instead of entering", () => {
  const html = read("app.html");
  const check = html.indexOf("if (session && this.forcedPasswordChange(session))");
  const enter = html.indexOf("if (session && !this.active) this.enter()");
  assert.notEqual(check, -1, "app.html does not check for a forced change");
  assert.ok(check < enter, "the check must come before enter(), whose first RPC would 42501");
  // replace(), not href: a flagged user pressing Back should not land in a
  // workspace that cannot answer.
  assert.match(html.slice(check, check + 400), /window\.location\.replace\(window\.location\.origin \+ '\/'\)/);
});

test("the forced path refreshes the session before leaving the page", () => {
  // Claims are minted at sign-in and not read live, so the access token in hand
  // still says force_password_change even once the database says otherwise --
  // and the SQL gate reads the token. Without the refresh the workspace loads
  // and every RPC answers 42501, which looks exactly like a failed change.
  const html = read("signin.html");
  const fn = html.slice(html.indexOf("async function submitNewPassword"), html.indexOf("const RESEND_COOLDOWN_SECONDS"));
  assert.match(fn, /muster-set-password/, "the forced path does not call the edge function");
  assert.match(fn, /refreshSession\(\)/, "the forced path does not refresh the session");
  assert.ok(
    fn.indexOf("muster-set-password") < fn.indexOf("refreshSession()"),
    "the refresh has to happen after the change, not before",
  );
  // And it must confirm the refresh actually cleared the flag rather than
  // assuming it: a silent failure here drops the user into an empty workspace.
  assert.match(fn, /isForced\(refreshed && refreshed\.session\)/);
});

test("the browser's minimum matches the server's", () => {
  const html = read("signin.html");
  assert.match(html, new RegExp(`const MIN_PASSWORD_CHARS = ${MIN_PASSWORD_CHARS};`),
    "signin.html and the edge function disagree about the minimum length");
  // The form's own attributes have to agree too, or the browser blocks the
  // submit with its own message before any of this code runs.
  assert.match(html, new RegExp(`id="rcPassword" required minlength="${MIN_PASSWORD_CHARS}"`));
  assert.match(html, new RegExp(`id="rcPassword2" required minlength="${MIN_PASSWORD_CHARS}"`));
  assert.match(html, new RegExp(`at least ${MIN_PASSWORD_CHARS} characters`));
});

test("the edge function refuses callers that are not actually flagged", () => {
  // Without this it is a general-purpose change-my-password-with-no-
  // reauthentication endpoint, which is strictly weaker than GoTrue's own.
  const src = read("supabase/functions/muster-set-password/index.ts");
  assert.match(src, /if \(!changeRequired\(user\.app_metadata as Record<string, unknown>\)\) \{/);
  assert.match(src, /reason: "not_required"/);
  // Identity comes from the verified token, never from the request body.
  assert.match(src, /userClient\.auth\.getUser\(\)/);
  assert.doesNotMatch(src, /body\.(user_id|email|uid)/, "identity must not be read from the request body");
});

test("the password and the flag clear in one admin call, never two", () => {
  // A separate clear-the-flag endpoint would be a bypass with extra steps, and
  // two sequential calls would leave a half-applied state on any failure.
  const src = read("supabase/functions/muster-set-password/index.ts");
  const call = src.slice(src.indexOf("admin.auth.admin.updateUserById"), src.indexOf("if (updErr)"));
  assert.match(call, /password,/, "the admin call does not set the password");
  assert.match(call, /app_metadata: clearedAppMetadata\(/, "the admin call does not clear the flag");
  assert.equal(src.match(/updateUserById/g)?.length, 1, "there must be exactly one admin update");
});
