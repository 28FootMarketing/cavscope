import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

// GHL checkout wiring, phase 1 (sales-assisted): payment is collected inside
// GHL itself (native invoicing / Stripe-connect), not a separate MUSTER-owned
// Stripe account. Once a deal is marked won, a GHL workflow's outbound
// Webhook action calls this function to provision the real tenant on the
// correct paid plan -- skipping the trial state self-serve signups start in.
//
// Required header:  x-muster-secret: <vault muster_ghl_webhook_secret>
//
// Required JSON body:
//   {
//     "tier": "muster" | "muster_partner" | "muster_enterprise",
//     "stage": "seed" | "fruit",              // required unless tier is muster_enterprise
//     "org_name": "Acme Corp",
//     "admin_name": "Jane Doe",
//     "admin_email": "jane@acmecorp.com",
//     "domain": "acmecorp.com",                // optional; becomes the first monitored website
//     "industry": "...",                       // optional
//     "country_code": "US",                    // optional, defaults to "US"
//     "region_code": "US-PA",                  // optional
//     "ghl_contact_id": "..."                  // optional, logged for traceability
//   }
//
// What this does: resolves or invites the admin's Supabase Auth account,
// runs the existing self-serve tenant-creation path (muster.do_onboard, via
// the public.muster_ghl_provision RPC -- same code real onboarding uses, not
// duplicated here), then immediately sets the org onto the plan the tier
// maps to (muster -> starter, muster_partner -> pro, muster_enterprise ->
// enterprise) instead of leaving it on the trial plan do_onboard defaults to.
//
// What this does NOT do: write the new muster_org_id back to the GHL contact
// as a custom field, or collect payment. Both need a GHL API key/location id,
// which isn't in this project's Vault -- see the checkout-flow scoping notes.
// A brand-new admin gets Supabase Auth's own invite email (no Resend key is
// configured for this project either); an admin who already has an account
// is reused as-is and gets no email.

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

const TIER_VALUES = ["muster", "muster_partner", "muster_enterprise"];
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const { data: secret } = await db.rpc("muster_ghl_webhook_secret");
  const provided = req.headers.get("x-muster-secret") ?? "";
  if (!secret || provided !== secret) return json({ error: "unauthorized" }, 401);

  let body: Record<string, unknown> = {};
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid JSON body" }, 400);
  }

  const tier = String(body.tier ?? "");
  const stage = body.stage != null ? String(body.stage) : null;
  const orgName = String(body.org_name ?? "").trim();
  const domain = String(body.domain ?? "").trim();
  const adminName = String(body.admin_name ?? "").trim();
  const adminEmail = String(body.admin_email ?? "").trim().toLowerCase();

  if (!TIER_VALUES.includes(tier)) {
    return json({ error: `tier must be one of ${TIER_VALUES.join(", ")}` }, 400);
  }
  if (!orgName) return json({ error: "org_name is required" }, 400);
  if (!adminEmail || !EMAIL_RE.test(adminEmail)) return json({ error: "a valid admin_email is required" }, 400);
  if (tier !== "muster_enterprise" && stage !== "seed" && stage !== "fruit") {
    return json({ error: "stage must be seed or fruit for muster and muster_partner" }, 400);
  }

  // Resolve or invite the admin's Supabase Auth account.
  const { data: existingAuthId, error: lookupErr } = await db.rpc("muster_find_auth_user_by_email", { p_email: adminEmail });
  if (lookupErr) return json({ error: `auth lookup failed: ${lookupErr.message}` }, 500);

  let authUserId = existingAuthId as string | null;
  let invited = false;
  if (!authUserId) {
    const { data: invite, error: inviteErr } = await db.auth.admin.inviteUserByEmail(adminEmail, {
      data: { name: adminName || undefined, source: "ghl_checkout" },
    });
    if (inviteErr || !invite?.user) {
      return json({ error: `could not create admin account: ${inviteErr?.message ?? "unknown error"}` }, 500);
    }
    authUserId = invite.user.id;
    invited = true;
  }

  const onboardPayload = {
    org_name: orgName,
    industry: body.industry ?? null,
    country_code: (typeof body.country_code === "string" && body.country_code) ? body.country_code.toUpperCase() : "US",
    region_code: body.region_code ?? null,
    website_url: domain ? (domain.startsWith("http") ? domain : `https://${domain}`) : undefined,
    website_name: orgName,
    admin_name: adminName,
    admin_email: adminEmail,
    tier,
    stage,
    ghl_contact_id: body.ghl_contact_id ?? null,
  };

  const { data: organization, error: provisionErr } = await db.rpc("muster_ghl_provision", {
    p: onboardPayload,
    p_auth_user_id: authUserId,
  });
  if (provisionErr) return json({ error: provisionErr.message }, 400);

  return json({ provisioned: true, admin_invited: invited, organization });
});
