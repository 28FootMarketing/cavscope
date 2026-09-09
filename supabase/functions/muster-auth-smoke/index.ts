import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

// End-to-end verification of the two GoTrue flows MUSTER depends on: the
// redirect allowlist, and password recovery from link to new-password sign-in.
//
// Why this exists as a function rather than a script: nothing outside Supabase's
// own network can be trusted to reach *.supabase.co from a build agent, and the
// only credential that can mint a recovery link is the service-role key, which
// must never leave the server. Both constraints point at an edge function.
//
// What it deliberately never returns: an access token, a recovery token, an
// action link, or a password. Every step reports a boolean and a redacted
// detail string. docs/EMAIL.md is explicit that a live link must not land in a
// transcript or a log, and a smoke test that leaks one is worse than no test.
//
// It sends NO email. admin/generate_link mints the link and hands it back; it
// does not go through the mailer. The email leg is proven separately by
// Resend's own delivery records.
//
// Invocation (same shared-secret pattern as every other engine function):
//   POST /functions/v1/muster-auth-smoke
//   Authorization: Bearer <publishable key>
//   x-muster-secret: <vault muster_cron_secret>

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

const db = createClient(SUPABASE_URL, SERVICE_KEY);

// The one account this function is allowed to touch. Step 5 rotates a password,
// which is destructive, so the target is pinned here rather than taken from the
// request. A caller who can reach this endpoint still cannot aim it at a real
// user's account.
const QA_EMAIL = "sentinel-qa-verify@28footmarketing.com";

const DEFAULT_APP_ORIGIN = "https://app.muster.partners";
// A host that is not, and must never be, on the allowlist. If GoTrue ever
// honours this one, the allowlist has been widened to something dangerous and
// the control step fails loudly.
const CONTROL_ORIGIN = "https://not-allowlisted.example.invalid";

type Step = { step: string; ok: boolean; detail: string };

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: { "content-type": "application/json" },
  });
}

// Everything that gets reported goes through here. Origin plus path is enough to
// tell a honoured redirect from a substituted one; the fragment is where the
// token lives, so it never survives.
function redact(url: string): string {
  try {
    const u = new URL(url);
    return u.origin + u.pathname + (u.hash ? "#<fragment redacted>" : "");
  } catch {
    return "<unparseable url>";
  }
}

function fragmentOf(url: string): URLSearchParams {
  const hash = url.includes("#") ? url.slice(url.indexOf("#") + 1) : "";
  return new URLSearchParams(hash);
}

// GoTrue validates redirect_to against the allowlist BEFORE it validates the
// token, so a deliberately invalid token is enough to read the allowlist
// decision out of the Location header. No email, no token consumed.
async function probeRedirect(redirectTo: string): Promise<string> {
  const url = `${SUPABASE_URL}/auth/v1/verify?type=recovery&token=smoke-probe-invalid` +
    `&redirect_to=${encodeURIComponent(redirectTo)}`;
  const res = await fetch(url, {
    method: "GET",
    redirect: "manual",
    headers: { apikey: ANON_KEY },
  });
  return res.headers.get("location") ?? "";
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const { data: secret } = await db.rpc("muster_engine_secret");
  const provided = req.headers.get("x-muster-secret") ?? "";
  if (!secret || provided !== secret) return json({ error: "unauthorized" }, 401);

  let body: Record<string, unknown> = {};
  try {
    body = await req.json();
  } catch { /* no body is fine; every input has a default */ }

  const appOrigin = typeof body.app_origin === "string" ? body.app_origin : DEFAULT_APP_ORIGIN;
  // Step 5 rotates a password. Default is to skip it, so the common case is a
  // read-only check that can run on a schedule without mutating anything.
  const rotate = body.rotate_password === true;

  const resetUrl = `${appOrigin}/reset`;
  const workspaceUrl = `${appOrigin}/app`;
  const steps: Step[] = [];
  let siteUrlFallback = "";

  // ---- 1. Allowlist: the URLs signin.html actually asks for ----------------
  for (const [label, want] of [["reset", resetUrl], ["workspace", workspaceUrl]] as const) {
    try {
      const loc = await probeRedirect(want);
      const ok = loc.startsWith(want + "#") || loc === want;
      steps.push({
        step: `allowlist:${label}`,
        ok,
        detail: ok
          ? `${want} honoured`
          : `requested ${want}, GoTrue substituted ${redact(loc)} -- add it to the project's Redirect URLs`,
      });
    } catch (e) {
      steps.push({ step: `allowlist:${label}`, ok: false, detail: `probe failed: ${e}` });
    }
  }

  // ---- 2. Control: a host that must be rejected ----------------------------
  // This is what makes the two steps above mean anything. Without it, a GoTrue
  // that honoured every redirect would score a clean pass.
  try {
    const loc = await probeRedirect(`${CONTROL_ORIGIN}/x`);
    const rejected = loc !== "" && !loc.startsWith(CONTROL_ORIGIN);
    siteUrlFallback = rejected ? redact(loc) : "";
    steps.push({
      step: "allowlist:control",
      ok: rejected,
      detail: rejected
        ? `rejected as expected; Site URL fallback is ${siteUrlFallback}`
        : `GoTrue HONOURED ${CONTROL_ORIGIN} -- the allowlist is open, this is an open-redirect`,
    });
  } catch (e) {
    steps.push({ step: "allowlist:control", ok: false, detail: `probe failed: ${e}` });
  }

  // ---- 3. The /reset landing page is actually served -----------------------
  // middleware.js gives /reset no route of its own; it falls to the catch-all
  // and signin.html renders the new-password form off type=recovery. If that
  // routing ever breaks, a recovery link lands on a page with no form and the
  // failure looks like "the email is broken".
  try {
    const res = await fetch(resetUrl, { headers: { "user-agent": "muster-auth-smoke" } });
    const html = await res.text();
    const hasForm = html.includes('id="recoveryState"') && html.includes('id="rcPassword"');
    steps.push({
      step: "reset_landing_page",
      ok: res.status === 200 && hasForm,
      detail: res.status === 200
        ? (hasForm
          ? `${resetUrl} serves signin.html with the new-password form`
          : `${resetUrl} returned 200 but has no recovery form -- wrong page is being served`)
        : `${resetUrl} returned ${res.status}`,
    });
  } catch (e) {
    steps.push({ step: "reset_landing_page", ok: false, detail: `fetch failed: ${e}` });
  }

  // ---- 4. Mint a real recovery link ---------------------------------------
  let actionLink = "";
  try {
    const res = await fetch(`${SUPABASE_URL}/auth/v1/admin/generate_link`, {
      method: "POST",
      headers: {
        apikey: SERVICE_KEY,
        authorization: `Bearer ${SERVICE_KEY}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({ type: "recovery", email: QA_EMAIL, redirect_to: resetUrl }),
    });
    const data = await res.json();
    actionLink = typeof data?.action_link === "string" ? data.action_link : "";
    steps.push({
      step: "generate_recovery_link",
      ok: res.status === 200 && actionLink !== "",
      detail: res.status === 200
        ? `recovery link minted for ${QA_EMAIL} (link withheld)`
        : `generate_link returned ${res.status}: ${JSON.stringify(data?.msg ?? data?.error ?? data)}`,
    });
  } catch (e) {
    steps.push({ step: "generate_recovery_link", ok: false, detail: `request failed: ${e}` });
  }

  // ---- 5. Follow it, the way a mail client would ---------------------------
  let accessToken = "";
  if (actionLink) {
    try {
      const res = await fetch(actionLink, { method: "GET", redirect: "manual", headers: { apikey: ANON_KEY } });
      const loc = res.headers.get("location") ?? "";
      const frag = fragmentOf(loc);
      accessToken = frag.get("access_token") ?? "";
      const landsRight = loc.startsWith(resetUrl + "#");
      const isRecovery = frag.get("type") === "recovery";
      steps.push({
        step: "recovery_link_redirect",
        ok: landsRight && isRecovery && accessToken !== "",
        detail: landsRight
          ? (isRecovery && accessToken
            ? `lands on ${resetUrl} with a recovery session in the fragment`
            : `lands on ${resetUrl} but type=${frag.get("type") ?? "<none>"}, access_token ${accessToken ? "present" : "MISSING"}` +
              (frag.get("error") ? ` (error=${frag.get("error")})` : ""))
          : `landed on ${redact(loc)} instead of ${resetUrl}`,
      });
    } catch (e) {
      steps.push({ step: "recovery_link_redirect", ok: false, detail: `follow failed: ${e}` });
    }
  } else {
    steps.push({ step: "recovery_link_redirect", ok: false, detail: "skipped: no link to follow" });
  }

  // ---- 6. Exercise what signin.html does with that session -----------------
  // signin.html calls sb.auth.updateUser({ password }) on the recovery session.
  // This is the same PUT /auth/v1/user underneath. Off by default because it
  // mutates; the steps above already prove the whole delivery path.
  if (rotate && accessToken) {
    const newPassword = `Sm0ke-${crypto.randomUUID()}`;
    try {
      const res = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
        method: "PUT",
        headers: {
          apikey: ANON_KEY,
          authorization: `Bearer ${accessToken}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({ password: newPassword }),
      });
      const data = await res.json();
      steps.push({
        step: "set_new_password",
        ok: res.status === 200,
        detail: res.status === 200
          ? `password set on ${QA_EMAIL} via the recovery session`
          : `updateUser returned ${res.status}: ${JSON.stringify(data?.msg ?? data?.error_description ?? data)}`,
      });
    } catch (e) {
      steps.push({ step: "set_new_password", ok: false, detail: `request failed: ${e}` });
    }

    // The step that closes the loop: a reset nobody can sign in with is not a
    // reset. Anything short of this passes on a password that was never stored.
    try {
      const res = await fetch(`${SUPABASE_URL}/auth/v1/token?grant_type=password`, {
        method: "POST",
        headers: { apikey: ANON_KEY, "content-type": "application/json" },
        body: JSON.stringify({ email: QA_EMAIL, password: newPassword }),
      });
      const data = await res.json();
      steps.push({
        step: "sign_in_with_new_password",
        ok: res.status === 200 && typeof data?.access_token === "string",
        detail: res.status === 200
          ? "signed in with the new password"
          : `token returned ${res.status}: ${JSON.stringify(data?.msg ?? data?.error_description ?? data)}`,
      });
    } catch (e) {
      steps.push({ step: "sign_in_with_new_password", ok: false, detail: `request failed: ${e}` });
    }
  } else if (rotate) {
    steps.push({ step: "set_new_password", ok: false, detail: "skipped: no recovery session to use" });
  }


  // ---- 7. What GoTrue actually rendered and handed to Resend ---------------
  // Optional: pass resend_email_id to check a message that was ALREADY sent.
  // Deliberately does not send one -- the QA sentinel is not a real mailbox, so
  // every send here is a hard bounce against the sending domain's reputation.
  //
  // The body contains a live confirmation link. It is read here and never
  // returned: the only things that leave this function are the subject, two
  // booleans, and the ORIGIN of the redirect target. That last one is the whole
  // point -- a template can look perfect and still send people to the wrong host.
  const resendEmailId = typeof body.resend_email_id === "string" ? body.resend_email_id : "";
  if (resendEmailId) {
    try {
      const key = Deno.env.get("RESEND_API_KEY") ?? "";
      if (!key) throw new Error("RESEND_API_KEY is not set on this project");
      const res = await fetch(`https://api.resend.com/emails/${resendEmailId}`, {
        headers: { authorization: `Bearer ${key}` },
      });
      const data = await res.json();
      const html: string = typeof data?.html === "string" ? data.html : "";
      const subject: string = typeof data?.subject === "string" ? data.subject : "";

      // Markers common to all six files in supabase/auth-email-templates/. If
      // these are missing, the dashboard is still serving GoTrue's stock
      // template and the pasted-from-repo step never happened.
      const branded = html.includes("muster-emblem.png") &&
        html.includes("MUSTER is website assurance by");

      // Pull the redirect target out of the rendered confirmation link.
      let redirectOrigin = "";
      const m = html.match(/https:\/\/[a-z0-9-]+\.supabase\.co\/auth\/v1\/verify\?[^"'<\s]+/i);
      if (m) {
        const raw = m[0].replace(/&amp;/g, "&");
        const target = new URL(raw).searchParams.get("redirect_to") ?? "";
        if (target) {
          const t = new URL(target);
          redirectOrigin = t.origin + t.pathname;
        }
      }

      steps.push({
        step: "email_template:branding",
        ok: branded,
        detail: branded
          ? `subject "${subject}" -- body is the MUSTER template`
          : `subject "${subject}" -- body is NOT the MUSTER template; paste supabase/auth-email-templates/ into the dashboard`,
      });
      steps.push({
        step: "email_template:redirect_target",
        ok: redirectOrigin.startsWith(appOrigin),
        detail: redirectOrigin
          ? `the link in the email sends the reader to ${redirectOrigin}`
          : "could not find a confirmation link in the rendered body",
      });
    } catch (e) {
      steps.push({ step: "email_template:branding", ok: false, detail: `lookup failed: ${e}` });
    }
  }

  const ok = steps.every((s) => s.ok);
  return json({
    ok,
    app_origin: appOrigin,
    site_url_fallback: siteUrlFallback || null,
    rotated_password: rotate,
    checked_at: new Date().toISOString(),
    steps,
  }, ok ? 200 : 500);
});
