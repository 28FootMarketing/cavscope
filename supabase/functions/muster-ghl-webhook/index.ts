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
//     "ghl_contact_id": "...",                 // optional, logged for traceability
//     "ghl_opportunity_id": "..."              // optional; required for the GHL write-back
//   }
//
// What this does: resolves or invites the admin's Supabase Auth account,
// runs the existing self-serve tenant-creation path (muster.do_onboard, via
// the public.muster_ghl_provision RPC -- same code real onboarding uses, not
// duplicated here), then immediately sets the org onto the plan the tier
// maps to (muster -> starter, muster_partner -> pro, muster_enterprise ->
// enterprise) instead of leaving it on the trial plan do_onboard defaults to.
// After a successful provision, if GHL_API_KEY/GHL_LOCATION_ID are configured
// and ghl_opportunity_id was provided, it writes the new org id back onto the
// GHL opportunity's "Muster Org ID" custom field (an opportunity-model field,
// matching Muster Tier/Stage/Industry/Region Code -- confirmed live via the
// custom_fields diagnostic below that all four already live on the
// opportunity, not the contact, so Muster Org ID follows the same model).
//
// Diagnostic-only paths (same x-muster-secret auth, no writes, no test data
// created in GHL):
//   POST { "diagnostic": "location" }      -- confirms GHL_LOCATION_ID points
//                                              at the intended sub-account
//   POST { "diagnostic": "custom_fields" } -- lists that location's custom
//                                              fields so the real field id
//                                              for "Muster Org ID" can be
//                                              read off once it's created,
//                                              instead of guessing one

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

const TIER_VALUES = ["muster", "muster_partner", "muster_enterprise"];
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const GHL_API_BASE = "https://services.leadconnectorhq.com";
const GHL_API_VERSION = "2021-07-28";

async function ghlFetch(path: string, init: RequestInit = {}) {
  const apiKey = Deno.env.get("GHL_API_KEY");
  if (!apiKey) return { ok: false, status: 0, body: { error: "GHL_API_KEY is not set" } };
  const res = await fetch(`${GHL_API_BASE}${path}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${apiKey}`,
      Version: GHL_API_VERSION,
      Accept: "application/json",
      "content-type": "application/json",
      ...(init.headers ?? {}),
    },
  });
  let body: unknown = null;
  try {
    body = await res.json();
  } catch {
    body = await res.text().catch(() => null);
  }
  return { ok: res.ok, status: res.status, body };
}

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

  if (body.diagnostic === "location") {
    const locationId = Deno.env.get("GHL_LOCATION_ID");
    if (!locationId) return json({ error: "GHL_LOCATION_ID is not set" }, 500);
    const result = await ghlFetch(`/locations/${locationId}`);
    return json({ diagnostic: "location", location_id_used: locationId, ghl_status: result.status, ghl_response: result.body }, result.ok ? 200 : 502);
  }

  if (body.diagnostic === "custom_fields") {
    const locationId = Deno.env.get("GHL_LOCATION_ID");
    if (!locationId) return json({ error: "GHL_LOCATION_ID is not set" }, 500);
    const model = typeof body.model === "string" ? body.model : "contact";
    const result = await ghlFetch(`/locations/${locationId}/customFields?model=${encodeURIComponent(model)}`);
    return json({ diagnostic: "custom_fields", model, ghl_status: result.status, ghl_response: result.body }, result.ok ? 200 : 502);
  }

  const tier = String(body.tier ?? "");
  const stage = body.stage != null ? String(body.stage) : null;
  const orgName = String(body.org_name ?? "").trim();
  const domain = String(body.domain ?? "").trim();
  const adminName = String(body.admin_name ?? "").trim();
  const adminEmail = String(body.admin_email ?? "").trim().toLowerCase();
  const ghlContactId = body.ghl_contact_id != null ? String(body.ghl_contact_id) : null;
  const ghlOpportunityId = body.ghl_opportunity_id != null ? String(body.ghl_opportunity_id) : null;

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
    ghl_contact_id: ghlContactId,
  };

  const { data: organization, error: provisionErr } = await db.rpc("muster_ghl_provision", {
    p: onboardPayload,
    p_auth_user_id: authUserId,
  });
  if (provisionErr) return json({ error: provisionErr.message }, 400);

  // Write the new org id back to the GHL opportunity, best-effort. A failure
  // here never undoes the provisioning above -- the tenant is real either
  // way -- it's reported back in the response so a failure is visible, not
  // silent. The "Muster Org ID" custom field's id is looked up by name at
  // call time rather than hardcoded, since GHL assigns its own opaque field
  // id when the field is created and there's no way to know it in advance.
  // Targets the opportunity (not the contact) because Muster Tier/Stage/
  // Industry/Region Code all live on the opportunity model -- confirmed live
  // via the custom_fields diagnostic -- and a field created on one model
  // isn't writable through the other model's update endpoint.
  let ghlWriteback: { attempted: boolean; ok?: boolean; status?: number; error?: unknown } = { attempted: false };
  const orgId = (organization as Record<string, unknown> | null)?.id;
  const locationId = Deno.env.get("GHL_LOCATION_ID");
  if (ghlOpportunityId && orgId != null && Deno.env.get("GHL_API_KEY") && locationId) {
    const fieldsResult = await ghlFetch(`/locations/${locationId}/customFields?model=opportunity`);
    const fields = (fieldsResult.body as { customFields?: Array<{ id: string; name: string }> } | null)?.customFields ?? [];
    const orgIdField = fields.find((f) => f.name?.toLowerCase() === "muster org id");
    if (!orgIdField) {
      ghlWriteback = { attempted: true, ok: false, error: 'no GHL opportunity custom field named "Muster Org ID" was found on this location' };
    } else {
      const result = await ghlFetch(`/opportunities/${ghlOpportunityId}`, {
        method: "PUT",
        body: JSON.stringify({ customFields: [{ id: orgIdField.id, field_value: String(orgId) }] }),
      });
      ghlWriteback = { attempted: true, ok: result.ok, status: result.status, error: result.ok ? undefined : result.body };
    }
  }

  return json({ provisioned: true, admin_invited: invited, organization, ghl_writeback: ghlWriteback });
});
