import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const FROM = "CavScope <team@mail.muster.partners>";
const LOGO_URL = "https://hjowfnzpomzxazmzywxw.supabase.co/storage/v1/object/public/brand-assets/muster-logo.jpg";

async function getSecret(name: string): Promise<string> {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/muster_get_secret`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      apikey: SERVICE_ROLE_KEY,
      Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
    },
    body: JSON.stringify({ p_name: name }),
  });
  if (!res.ok) throw new Error(`secret lookup failed for ${name}: ${res.status}`);
  return await res.json();
}

function esc(s: string): string {
  return String(s ?? "").replace(/[<>&]/g, (c) => ({ "<": "&lt;", ">": "&gt;", "&": "&amp;" }[c]!));
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  const expected = await getSecret("muster_beta_notify_secret");
  const provided = req.headers.get("x-muster-signal");
  if (!expected || provided !== expected) {
    return new Response("Unauthorized", { status: 401 });
  }

  const payload = await req.json().catch(() => null);
  if (!payload) {
    return new Response("Bad request", { status: 400 });
  }

  const { full_name, company_name, email, site_url } = payload;
  if (!email) {
    return new Response("Missing email", { status: 400 });
  }

  const firstName = String(full_name ?? "").trim().split(/\s+/)[0] || "there";
  const companyLabel = esc(company_name || "your business");
  const siteLabel = esc(site_url);

  const text = `You're confirmed for a free CavScope scan

Hi ${firstName},

Your site is queued: ${site_url}

What happens next:
- Your site is queued for scanning.
- We'll follow up at this address with your results.
- You'll get first access to bring CavScope into ${company_name || "your business"} once it's ready to purchase.

No card, no obligation. Just reply to this email if you have questions.

- The CavScope team`;

  const html = `<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
</head>
<body style="margin:0; padding:0; background-color:#12151A; font-family:-apple-system,'Segoe UI',Helvetica,Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background-color:#12151A;">
<tr><td align="center" style="padding:32px 16px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:520px;">

  <!-- Header / logo on the logo's own black field -->
  <tr>
    <td align="center" style="background-color:#0B0C0E; padding:28px 24px 22px; border-radius:6px 6px 0 0;">
      <img src="${LOGO_URL}" width="96" alt="CavScope" style="display:block; width:96px; height:96px; border:0;">
    </td>
  </tr>

  <!-- Status strip -->
  <tr>
    <td style="background-color:#1B2027; border-left:1px solid #2E3540; border-right:1px solid #2E3540; padding:10px 24px; font-family:'Courier New',monospace; font-size:11px; letter-spacing:0.06em; color:#D98E2F;">
      SIGNUP CONFIRMED &middot; SCAN QUEUED
    </td>
  </tr>

  <!-- Body card -->
  <tr>
    <td style="background-color:#1B2027; border-left:1px solid #2E3540; border-right:1px solid #2E3540; padding:6px 32px 8px;">
      <p style="color:#ECEFF2; font-size:16px; line-height:1.6; margin:22px 0 0;">Hi ${esc(firstName)},</p>
      <p style="color:#ECEFF2; font-size:16px; line-height:1.6; margin:14px 0 0;">You're confirmed for a free CavScope scan of</p>
      <p style="color:#D98E2F; font-size:17px; font-family:'Courier New',monospace; line-height:1.5; margin:6px 0 20px; word-break:break-all;">${siteLabel}</p>

      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background-color:#20262E; border:1px solid #2E3540; border-radius:4px; margin-bottom:20px;">
        <tr><td style="padding:18px 20px;">
          <p style="color:#8B94A0; font-size:11px; font-family:'Courier New',monospace; letter-spacing:0.06em; margin:0 0 10px;">WHAT HAPPENS NEXT</p>
          <p style="color:#ECEFF2; font-size:14.5px; line-height:1.7; margin:0 0 8px;">&bull;&nbsp; Your site is queued for scanning.</p>
          <p style="color:#ECEFF2; font-size:14.5px; line-height:1.7; margin:0 0 8px;">&bull;&nbsp; We'll follow up at this address with your results.</p>
          <p style="color:#ECEFF2; font-size:14.5px; line-height:1.7; margin:0;">&bull;&nbsp; You'll get first access to bring CavScope into ${companyLabel} once it's ready to purchase.</p>
        </td></tr>
      </table>

      <p style="color:#8B94A0; font-size:13.5px; line-height:1.6; margin:0 0 26px;">No card, no obligation. Just reply to this email if you have questions.</p>
    </td>
  </tr>

  <!-- Footer -->
  <tr>
    <td style="background-color:#1B2027; border:1px solid #2E3540; border-top:none; border-radius:0 0 6px 6px; padding:16px 32px 22px;">
      <p style="color:#5B6169; font-size:12px; line-height:1.6; margin:0;">&mdash; The CavScope team<br>28 Foot Systems</p>
    </td>
  </tr>

</table>
</td></tr>
</table>
</body>
</html>`;

  const resendKey = await getSecret("muster_resend_api_key");

  const emailRes = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${resendKey}`,
    },
    body: JSON.stringify({
      from: FROM,
      to: [email],
      subject: "You're confirmed — CavScope beta scan",
      text,
      html,
    }),
  });

  if (!emailRes.ok) {
    const detail = await emailRes.text();
    console.error("resend send failed", emailRes.status, detail);
    return new Response("Email send failed", { status: 502 });
  }

  return new Response("ok", { status: 200 });
});
