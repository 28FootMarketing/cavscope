// The sign-in page's input handling and redirect construction, tested against
// the functions actually shipped in signin.html.
//
//   node --experimental-strip-types --test tests/auth/signin.test.ts
//
// The functions are extracted from the page rather than copied, so editing them
// runs these assertions against the edit. What this guards, in order of how
// expensive the failure is:
//
//   1. emailRedirectTo is derived from window.location.origin and never from a
//      query parameter, so there is no open-redirect surface to allowlist.
//   2. The magic-link button is type="button", so the browser's own type=email
//      validation never runs on that path. Before isValidEmail, anything typed
//      into the field was sent to GoTrue.
//   3. Every outcome shows one message, so the form cannot be used to test
//      which addresses have MUSTER accounts.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const html = readFileSync(join(repoRoot, "signin.html"), "utf8");

/** Pull one function's source out of the page and make it callable. */
function extract(name: string): Function {
  const start = html.indexOf(`  function ${name}(`);
  assert.notEqual(start, -1, `${name} not found in signin.html`);
  // Functions are two-space indented at this level; the next line that starts
  // with exactly two spaces and a closing brace ends it.
  const end = html.indexOf("\n  }", start);
  assert.ok(end > start, `could not find the end of ${name}`);
  const src = html.slice(start, end + 4);
  return new Function(`${src}; return ${name};`)();
}

const normalizeEmail = extract("normalizeEmail") as (v: unknown) => string;
const isValidEmail = extract("isValidEmail") as (v: string) => boolean;
const describeAuthError = extract("describeAuthError") as (v: unknown) => string;

// ---------------------------------------------------------------------------
// Email normalization
// ---------------------------------------------------------------------------

test("addresses are lowercased and trimmed, because GoTrue compares them that way", () => {
  assert.equal(normalizeEmail("  Anthony@Example.COM  "), "anthony@example.com");
  assert.equal(normalizeEmail("USER@EXAMPLE.ORG"), "user@example.org");
});

// Copying an address out of a mail client is the common way this arrives.
test("a pasted \"Name <addr>\" is reduced to the address", () => {
  assert.equal(normalizeEmail("Anthony Washington <unc@example.com>"), "unc@example.com");
  assert.equal(normalizeEmail("<unc@example.com>"), "unc@example.com");
});

test("normalizing junk does not throw", () => {
  for (const v of [null, undefined, "", "   ", 42, {}]) {
    assert.doesNotThrow(() => normalizeEmail(v));
  }
  assert.equal(normalizeEmail(null), "");
});

// ---------------------------------------------------------------------------
// Validation. REGRESSION: the magic-link button is type="button" with an
// onclick, so the browser never validated this field on that path.
// ---------------------------------------------------------------------------

test("real addresses are accepted", () => {
  for (const e of [
    "unc@example.com",
    "first.last@sub.example.co.uk",
    "a+tag@example.io",
    "x_y-z@example-host.com",
    "user@example.museum",
  ]) {
    assert.equal(isValidEmail(e), true, `${e} should be accepted`);
  }
});

test("what a person actually mistypes is rejected", () => {
  for (const e of [
    "",                    // empty
    "unc",                 // no @
    "unc@",                // no domain
    "@example.com",        // no local part
    "unc@example",         // no dot in domain
    "unc@example.",        // trailing dot
    "unc@exa..mple.com",   // doubled dot
    "unc @example.com",    // space
    "unc@example.com ",    // trailing space survives only if not normalized
    "unc@example.c",       // one-letter TLD
    "unc@@example.com",    // doubled @
  ]) {
    assert.equal(isValidEmail(e), false, `${JSON.stringify(e)} should be rejected`);
  }
});

test("an absurdly long address is rejected before it reaches the network", () => {
  assert.equal(isValidEmail("a".repeat(250) + "@example.com"), false);
});

// Being stricter than this rejects valid addresses, which is a worse failure
// than accepting one the mail system will bounce.
test("validation does not try to out-guess the mail system", () => {
  assert.equal(isValidEmail("weird!#$%&'*+-/=?^_`{|}~@example.com"), true);
});

// ---------------------------------------------------------------------------
// Error messaging
// ---------------------------------------------------------------------------

test("an expired or consumed link gets the actionable message, not GoTrue's", () => {
  for (const raw of [
    "Email+link+is+invalid+or+has+expired",
    "otp_expired",
    "Token has expired or is invalid",
  ]) {
    const out = describeAuthError(raw);
    assert.match(out, /expired or is no longer valid/);
    assert.match(out, /Request a new secure sign-in link/);
  }
});

test("a rate limit is named as one, so the user waits instead of retrying", () => {
  assert.match(describeAuthError("For security purposes, you can only request this after 55 seconds"),
    /Wait a minute/);
  assert.match(describeAuthError("429 Too Many Requests"), /Wait a minute/);
});

test("anything else collapses to one message rather than surfacing internals", () => {
  const out = describeAuthError("PGRST301 jwt malformed at /auth/v1/verify");
  assert.doesNotMatch(out, /PGRST|jwt|verify|auth\/v1/i,
    "internal detail must not reach the user");
  assert.match(out, /could not be completed/);
});

test("no error means no message", () => {
  assert.equal(describeAuthError(""), "");
  assert.equal(describeAuthError(null), "");
});

// ---------------------------------------------------------------------------
// Redirect construction. This is the open-redirect check.
// ---------------------------------------------------------------------------

test("the post-auth destination is built from the origin, never from the URL", () => {
  const src = html.slice(html.indexOf("const WORKSPACE_URL"), html.indexOf("let sb = null;"));
  assert.match(src, /const WORKSPACE_URL = window\.location\.origin \+ '\/app';/);
  assert.match(src, /const RESET_URL = window\.location\.origin \+ '\/reset';/);
  // If either ever reads a query parameter, this page gains an open redirect.
  assert.doesNotMatch(src, /searchParams|URLSearchParams|location\.search/,
    "the redirect target must not be influenced by the query string");
});

test("no query parameter anywhere on the page feeds a redirect", () => {
  // The page reads the hash (for recovery + error), never the search string.
  const script = html.slice(html.indexOf("<script>"));
  assert.doesNotMatch(script, /location\.search/,
    "signin.html must not read the query string");
  for (const m of script.matchAll(/location\.href\s*=\s*([^;]+);/g)) {
    assert.match(m[1], /WORKSPACE_URL/,
      `navigation target ${m[1].trim()} is not the allowlisted workspace URL`);
  }
});

// ---------------------------------------------------------------------------
// Enumeration and account creation
// ---------------------------------------------------------------------------

// REGRESSION: signInWithOtp defaults shouldCreateUser to true. Left at the
// default, this form creates an account for any address typed into it, which is
// both an open signup path and an oracle for which addresses are already known.
test("the magic-link request never creates an account", () => {
  const src = html.slice(html.indexOf("async function requestLink"));
  assert.match(src, /shouldCreateUser:\s*false/);
});

test("both link types end on the same neutral confirmation", () => {
  const src = html.slice(html.indexOf("function showSent"), html.indexOf("function startResendCooldown"));
  assert.match(src, /Check your email for your secure sign-in link/);
  assert.match(src, /has a CavScope account/);
});

test("request failures are swallowed rather than reported to the user", () => {
  const src = html.slice(html.indexOf("async function requestLink"), html.indexOf("async function submitMagicLink"));
  // A catch that re-threw or set a message would leak whether the address
  // exists and whether it was rate limited.
  assert.match(src, /catch \(_\)/);
  assert.doesNotMatch(src, /setMsg|setResetMsg|throw/);
});

// ---------------------------------------------------------------------------
// Abuse protection and double submit
// ---------------------------------------------------------------------------

test("a request in flight blocks another one", () => {
  for (const fn of ["submitMagicLink", "submitPassword", "submitResetRequest"]) {
    const src = html.slice(html.indexOf(`async function ${fn}(`));
    assert.match(src.slice(0, 400), /if \(busy\)/, `${fn} does not check the in-flight lock`);
  }
});

test("the resend cooldown is enforced with disabled, not pointer-events", () => {
  const src = html.slice(html.indexOf("function startResendCooldown"), html.indexOf("async function resendLast"));
  assert.match(src, /link\.disabled = true/);
  // pointer-events leaves the control reachable by Tab and activatable by
  // Enter, so the cooldown applied to the mouse only.
  assert.doesNotMatch(src, /pointerEvents/,
    "a pointer-events cooldown does not apply to the keyboard");
});

test("the resend control is a button, so disabled actually disables it", () => {
  assert.match(html, /<button type="button" id="resendLink"/);
  assert.doesNotMatch(html, /<a[^>]*id="resendLink"/);
});

// ---------------------------------------------------------------------------
// Accessibility
// ---------------------------------------------------------------------------

test("every input has a real label, not a placeholder standing in for one", () => {
  for (const id of ["suEmail", "suPassword", "rsEmail", "rcPassword", "rcPassword2"]) {
    assert.ok(html.includes(`for="${id}"`), `${id} has no <label for>`);
  }
});

test("errors are announced and tied to the field they belong to", () => {
  assert.match(html, /id="signinMsg" role="status" aria-live="polite"/);
  assert.match(html, /id="resetMsg" role="status" aria-live="polite"/);
  assert.match(html, /id="resendMsg" role="status" aria-live="polite"/);
  for (const id of ["suEmail", "suPassword", "rsEmail"]) {
    const tag = html.match(new RegExp(`<input[^>]*id="${id}"[^>]*>`, "s"));
    assert.ok(tag, `${id} not found`);
    assert.match(tag[0], /aria-describedby=/, `${id} is not tied to its message region`);
  }
});

test("buttons expose their busy state rather than only changing colour", () => {
  const src = html.slice(html.indexOf("function setBusy"), html.indexOf("function setFieldError"));
  assert.match(src, /b\.disabled = !!on/);
  assert.match(src, /aria-busy/);
});

test("an invalid field is marked invalid and takes focus", () => {
  const src = html.slice(html.indexOf("function setFieldError"), html.indexOf("function setMsg"));
  assert.match(src, /aria-invalid/);
  assert.match(src, /\.focus\(\)/);
});

// ---------------------------------------------------------------------------
// Session handling
// ---------------------------------------------------------------------------

test("the client is configured for session detection and refresh", () => {
  assert.match(html, /persistSession:\s*true/);
  assert.match(html, /autoRefreshToken:\s*true/);
  assert.match(html, /detectSessionInUrl:\s*true/);
});

test("only the publishable key is in the page", () => {
  assert.match(html, /sb_publishable_/);
  // A service-role key here would hand every visitor full database access.
  assert.doesNotMatch(html, /service_role|sb_secret_|SUPABASE_SERVICE/i);
  assert.doesNotMatch(html, /RESEND_API_KEY|re_[A-Za-z0-9]{16}/,
    "no Resend credential belongs in a page served to the browser");
});
