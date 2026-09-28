import "jsr:@supabase/functions-js/edge-runtime.d.ts";

// Recovered into git on 2026-09-25 from the live deploy (version 6, pasted
// with no source file). Verbatim. Uploads a base64 payload into the public
// brand-assets bucket (the SITREP logo lives there) and returns its public URL.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const BUCKET = "brand-assets";

function authHeaders(extra: Record<string, string> = {}) {
  return {
    Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
    apikey: SERVICE_ROLE_KEY,
    ...extra,
  };
}

async function getSecret(name: string): Promise<string> {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/muster_get_secret`, {
    method: "POST",
    headers: authHeaders({ "Content-Type": "application/json" }),
    body: JSON.stringify({ p_name: name }),
  });
  if (!res.ok) throw new Error(`secret lookup failed for ${name}: ${res.status}`);
  return await res.json();
}

async function ensureBucket() {
  const check = await fetch(`${SUPABASE_URL}/storage/v1/bucket/${BUCKET}`, {
    headers: authHeaders(),
  });
  if (check.ok) return;

  const create = await fetch(`${SUPABASE_URL}/storage/v1/bucket`, {
    method: "POST",
    headers: authHeaders({ "Content-Type": "application/json" }),
    body: JSON.stringify({ id: BUCKET, name: BUCKET, public: true }),
  });
  if (!create.ok) {
    const t = await create.text();
    throw new Error("bucket create failed: " + t);
  }
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  const expected = await getSecret("muster_asset_admin_secret");
  const provided = req.headers.get("x-muster-signal");
  if (!expected || provided !== expected) {
    return new Response("Unauthorized", { status: 401 });
  }

  const payload = await req.json().catch(() => null);
  if (!payload || !payload.path || !payload.contentBase64 || !payload.contentType) {
    return new Response("Bad request: need path, contentBase64, contentType", { status: 400 });
  }

  try {
    await ensureBucket();
  } catch (e) {
    return new Response("Bucket ensure failed: " + String(e), { status: 502 });
  }

  const bytes = Uint8Array.from(atob(payload.contentBase64), (c) => c.charCodeAt(0));

  const uploadRes = await fetch(
    `${SUPABASE_URL}/storage/v1/object/${BUCKET}/${payload.path}`,
    {
      method: "POST",
      headers: authHeaders({ "Content-Type": payload.contentType, "x-upsert": "true" }),
      body: bytes,
    }
  );

  if (!uploadRes.ok) {
    const detail = await uploadRes.text();
    console.error("storage upload failed", uploadRes.status, detail);
    return new Response("Upload failed: " + detail, { status: 502 });
  }

  const publicUrl = `${SUPABASE_URL}/storage/v1/object/public/${BUCKET}/${payload.path}`;
  return new Response(JSON.stringify({ url: publicUrl }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
});
