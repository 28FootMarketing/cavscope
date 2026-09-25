import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { changeRequired, clearedAppMetadata, validateNewPassword } from "./core.ts";

// Satisfies a forced password change, and is the ONLY thing that can.
//
// WHY THIS EXISTS AT ALL, rather than the browser just calling
// sb.auth.updateUser({ password }):
//
//   force_password_change lives in app_metadata, which is writable only with
//   the service role. That is the whole reason the flag is worth anything --
//   a user cannot clear their own. But it means the password change and the
//   flag clear cannot both happen in the browser.
//
//   Splitting them would be worse than not having the flag. A "clear my flag"
//   endpoint the browser can call is an endpoint that clears the flag without
//   a password ever changing; every user would find it in about a minute, and
//   the control register would still say the change was enforced. So this
//   function does BOTH, in one admin call, or neither. There is no way to
//   reach the clear without also setting a password that passed the policy.
//
// The gate itself is not here. It is muster.password_change_required() in
// Postgres, wired into the authorization spine (current_user_id,
// is_super_admin, org_role, shares_org_with, onboarding_caller,
// ensure_user_from_auth) by migration 20260915230805. A flagged JWT resolves
// to no role in any organization, so every tenant-scoped RPC and policy
// answers empty. The browser's redirect to the password form is the
// explanation; the SQL is the enforcement. Do not let anyone describe the
// redirect as the control.
//
// This function is exempt from its own gate because it holds the service role,
// which is what makes the exemption safe to state: a service-role JWT carries
// no app_metadata, so the predicate is false for it by construction.
//
// Required secrets (all three are project defaults, nothing to set by hand):
//   SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY
//
// Policy and the metadata merge live in core.ts, under test.

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

const URL_ = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

/**
 * True when `password` is already this account's password.
 *
 * A forced change that accepts the current password back is theatre: the
 * provisioner who knew the temporary password still knows it, the flag clears,
 * and the audit trail says the rotation happened. So probe for it.
 *
 * The probe is a real sign-in attempt against GoTrue, because nothing else can
 * answer the question -- the stored value is a bcrypt hash and this function
 * cannot see it. Two consequences are accepted deliberately:
 *
 *   - The success case mints a session, which is immediately revoked below.
 *   - The failure case (the good case) records a failed password attempt for
 *     this account, from this function's IP rather than the user's. At CavScope's
 *     size that is nothing; if GoTrue's token-endpoint rate limit is ever
 *     tightened, this is the call that will hit it first.
 *
 * A network failure returns false -- fails open. The probe is a quality check,
 * not the security boundary; the boundary is that the flag cannot clear
 * without SOME password passing the policy. Blocking a legitimate change
 * because GoTrue was briefly unreachable would be the worse failure.
 */
async function isCurrentPassword(email: string, password: string): Promise<boolean> {
  try {
    const res = await fetch(`${URL_}/auth/v1/token?grant_type=password`, {
      method: "POST",
      headers: { "Content-Type": "application/json", apikey: ANON },
      body: JSON.stringify({ email, password }),
    });
    if (!res.ok) return false;
    const body = await res.json().catch(() => ({}));
    const token = (body as { access_token?: string }).access_token;
    if (!token) return false;
    // Do not leave the probe's session lying around. Best effort: if this
    // fails the session still expires on its own, and the request is rejected
    // below either way.
    await fetch(`${URL_}/auth/v1/logout`, {
      method: "POST",
      headers: { apikey: ANON, Authorization: `Bearer ${token}` },
    }).catch(() => {});
    return true;
  } catch {
    return false;
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ ok: false, reason: "method", message: "POST only" }, 405);

  const authHeader = req.headers.get("Authorization") ?? "";
  if (!authHeader.toLowerCase().startsWith("bearer ")) {
    return json({ ok: false, reason: "no_token", message: "Sign in first." }, 401);
  }

  // getUser() with the caller's header verifies the JWT signature and expiry
  // at GoTrue. The identity comes from there and nowhere else -- never from
  // the request body, which the caller controls. This is what stops one signed-in
  // user setting another's password.
  const userClient = createClient(URL_, ANON, { global: { headers: { Authorization: authHeader } } });
  const { data: { user }, error: userErr } = await userClient.auth.getUser();
  if (userErr || !user) {
    return json({ ok: false, reason: "invalid_token", message: "Your session has expired. Sign in again." }, 401);
  }

  // Only an account actually carrying the flag may use this endpoint. Without
  // this check it would be a general-purpose "change my password with no
  // reauthentication" endpoint -- strictly weaker than GoTrue's own
  // updateUser, which at least requires a fresh session for a password change.
  if (!changeRequired(user.app_metadata as Record<string, unknown>)) {
    return json({
      ok: false,
      reason: "not_required",
      message: "This account does not have a password change pending. Change it from your workspace settings.",
    }, 403);
  }

  let body: { password?: unknown } = {};
  try {
    body = await req.json();
  } catch {
    return json({ ok: false, reason: "bad_json", message: "Malformed request." }, 400);
  }

  const verdict = validateNewPassword(body.password, user.email ?? "");
  if (!verdict.ok) return json({ ok: false, reason: verdict.reason, message: verdict.message }, 400);
  const password = body.password as string;

  if (await isCurrentPassword(user.email ?? "", password)) {
    return json({
      ok: false,
      reason: "unchanged",
      message: "That is already your password. Choose a different one.",
    }, 400);
  }

  // One admin call sets the password AND clears the flag. Not two: a partial
  // success here is the failure mode worth designing out. If this call fails,
  // nothing changed and the user is still gated, which is the safe direction.
  const admin = createClient(URL_, SERVICE);
  const { error: updErr } = await admin.auth.admin.updateUserById(user.id, {
    password,
    app_metadata: clearedAppMetadata(user.app_metadata as Record<string, unknown>, new Date().toISOString()),
  });
  if (updErr) {
    // GoTrue's own message is surfaced because its refusals here are
    // actionable (its own minimum length, its leaked-password check). The
    // password itself is never echoed and never logged.
    return json({ ok: false, reason: "update_failed", message: updErr.message }, 400);
  }

  // The caller's existing access token still carries force_password_change:true
  // until it is refreshed -- claims are minted at sign-in, not read live. The
  // browser must call refreshSession() before it can do anything, or the SQL
  // gate will keep answering empty and it will look like the change did not
  // take. Said here so the next person to read this function knows the client
  // step is required, not decorative.
  return json({ ok: true, refresh_required: true });
});
