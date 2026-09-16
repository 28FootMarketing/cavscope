// The landing page's stray auth fragment forwarder.
//
//   node --experimental-strip-types --test tests/auth/landing-auth-fragment.test.ts
//
// index.html cannot complete a sign-in -- a Supabase session is stored
// per-origin and this is not the app origin -- but it receives auth fragments
// anyway, because GoTrue substitutes the project's Site URL for any link minted
// without a redirect_to, and Site URL has pointed at this host. On 2026-09-15 a
// real magiclink landed on https://www.muster.partners/ carrying a valid
// access_token and refresh_token, and the page rendered marketing copy at
// someone holding a live session they had no way to spend.
//
// The forwarder hands the fragment to app host root, which is the one page that
// handles every arrival: a live session, a recovery link, and an expired one.
//
// These tests pull the real function out of index.html and run it. The two that
// matter most are the negatives -- an in-page anchor must never redirect, and
// the forwarder must not be able to loop -- because those are the ways a
// redirect on page load stops being a fix and becomes an outage.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const html = readFileSync(join(ROOT, "index.html"), "utf8");

const AUTH_HOST = "https://app.muster.partners";

// Extract the real source rather than reimplementing it: a copy would keep
// passing after index.html changed, which is the failure this file exists to
// prevent.
function loadAuthFragmentTarget(): (hash: string | null, origin: string) => string | null {
  const host = /const MUSTER_AUTH_HOST = '([^']+)';/.exec(html);
  assert.ok(host, "MUSTER_AUTH_HOST not found in index.html");
  assert.equal(host[1], AUTH_HOST, "the forwarder points somewhere unexpected");

  const fn = /function authFragmentTarget\(hash, origin\) \{[\s\S]*?\n    \}/.exec(html);
  assert.ok(fn, "authFragmentTarget not found in index.html");

  return new Function(
    "MUSTER_AUTH_HOST",
    `${fn[0]}\nreturn authFragmentTarget;`,
  )(AUTH_HOST);
}

const authFragmentTarget = loadAuthFragmentTarget();

// The fragment shape GoTrue actually delivers on a successful magiclink, taken
// from the 2026-09-15 arrival with the token bodies replaced.
const SUCCESS_HASH =
  "#access_token=header.payload.signature&expires_at=1789516130&expires_in=3600" +
  "&refresh_token=5l63x4kngdyw&sb=&token_type=bearer&type=magiclink";

test("a completed sign-in is forwarded to the app host with the fragment intact", () => {
  const target = authFragmentTarget(SUCCESS_HASH, "https://www.muster.partners");
  assert.equal(target, AUTH_HOST + "/" + SUCCESS_HASH);
  // Nothing may be dropped on the way: signin.html reads type, and supabase-js
  // needs BOTH tokens -- an access_token alone yields a session that cannot
  // refresh and dies in an hour.
  assert.match(String(target), /access_token=/);
  assert.match(String(target), /refresh_token=/);
  assert.match(String(target), /type=magiclink/);
});

test("a recovery link is forwarded to root, where the new-password form lives", () => {
  const hash = "#access_token=a.b.c&refresh_token=r&type=recovery";
  const target = authFragmentTarget(hash, "https://www.muster.partners");
  // Root, not /app. signin.html branches on type=recovery; app.html would
  // consume the recovery session and show the workspace instead of a password
  // form, stranding the user in the exact way docs/EMAIL.md describes.
  assert.equal(target, AUTH_HOST + "/" + hash);
  assert.doesNotMatch(String(target), /\/app#/);
});

test("an expired or invalid link is forwarded too, so the error has somewhere to show", () => {
  const hash =
    "#error=access_denied&error_code=otp_expired" +
    "&error_description=Email+link+is+invalid+or+has+expired";
  assert.equal(
    authFragmentTarget(hash, "https://www.muster.partners"),
    AUTH_HOST + "/" + hash,
  );
});

test("an in-page anchor never redirects", () => {
  for (const hash of ["#pricing", "#how-it-works", "#", "", null]) {
    assert.equal(
      authFragmentTarget(hash, "https://www.muster.partners"),
      null,
      `anchor ${JSON.stringify(hash)} must not leave the page`,
    );
  }
});

test("a fragment with key=value pairs but no auth keys never redirects", () => {
  // Analytics and campaign tooling both write fragments. Redirecting on any
  // '=' would send a reader of the landing page to a sign-in screen.
  for (const hash of ["#utm_source=x", "#section=pricing&tab=partner", "#=", "#a=1"]) {
    assert.equal(authFragmentTarget(hash, "https://www.muster.partners"), null);
  }
});

test("the forwarder cannot loop back onto itself", () => {
  // index.html is not served on the app host today. If that ever changes, a
  // self-redirect would be an infinite reload on a page carrying credentials.
  assert.equal(authFragmentTarget(SUCCESS_HASH, AUTH_HOST), null);
});

test("both the apex and www forms of the marketing host forward", () => {
  for (const origin of ["https://muster.partners", "https://www.muster.partners"]) {
    assert.equal(authFragmentTarget(SUCCESS_HASH, origin), AUTH_HOST + "/" + SUCCESS_HASH);
  }
});

test("the forwarder runs in <head>, ahead of the body", () => {
  // A forwarder that runs after the page paints shows the marketing page to
  // someone holding a live session before moving them, which is most of the
  // confusion it is meant to remove.
  const call = html.indexOf("forwardStrayAuthFragment");
  const body = html.indexOf("<body>");
  assert.notEqual(call, -1, "forwardStrayAuthFragment not found in index.html");
  assert.ok(call < body, "the forwarder must run before <body>");
});

test("it uses replace(), so tokens are not left in this origin's history", () => {
  const fn = /function forwardStrayAuthFragment\(\) \{[\s\S]*?\n    \}/.exec(html);
  assert.ok(fn, "forwardStrayAuthFragment not found in index.html");
  assert.match(fn[0], /window\.location\.replace\(/);
  assert.doesNotMatch(fn[0], /location\.(href\s*=|assign\()/);
});

test("the landing page still refuses to consume the fragment itself", () => {
  // The forwarder does not replace detectSessionInUrl:false -- it depends on
  // it. With detection on, supabase-js would parse and spend the fragment
  // before the redirect, and the app host would receive tokens already burned.
  assert.match(html, /detectSessionInUrl:\s*false/);
  assert.doesNotMatch(html, /detectSessionInUrl:\s*true/);
});
