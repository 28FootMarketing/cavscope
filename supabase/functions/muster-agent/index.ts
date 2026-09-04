import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

// MUSTER agent gateway. Makes every workspace usable by an AI agent or AI employee.
//
// Auth: header  x-muster-api-key: mk_...   (issued by public.muster_create_api_key, hashed at rest)
// Two surfaces on the same URL:
//   1. MCP (Streamable HTTP, stateless JSON-RPC 2.0): initialize, ping, tools/list, tools/call
//      Point any MCP client at https://<project>.supabase.co/functions/v1/muster-agent with the header above.
//   2. REST: POST { "tool": "list_findings", "args": { "website_id": 3 } }  ->  { "ok": true, "result": ... }
//      GET  /muster-agent  ->  tool catalog (JSON Schema per tool)
// All authorization and org scoping is enforced in SQL (public.muster_engine_agent_call).

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const PROTOCOL_VERSION = "2025-06-18";

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "access-control-allow-origin": "*",
      "access-control-allow-headers": "authorization, x-muster-api-key, content-type, mcp-session-id, mcp-protocol-version",
      "access-control-allow-methods": "GET, POST, OPTIONS" },
  });
}
function rpcError(id: unknown, code: number, message: string, data?: unknown) {
  return { jsonrpc: "2.0", id: id ?? null, error: { code, message, ...(data !== undefined ? { data } : {}) } };
}
function pgStatus(msg: string): number {
  if (/forbidden|lacks the|requires|disabled|42501/i.test(msg)) return 403;
  if (/not found/i.test(msg)) return 404;
  if (/required|must be|invalid|unknown tool/i.test(msg)) return 400;
  return 500;
}

async function resolveKey(req: Request) {
  const key = req.headers.get("x-muster-api-key") ?? (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!key || !key.startsWith("mk_")) return { ctx: null, error: "missing x-muster-api-key header" };
  const { data, error } = await db.rpc("muster_engine_resolve_api_key", { p_key: key });
  if (error) return { ctx: null, error: error.message };
  if (!data) return { ctx: null, error: "invalid api key" };
  if (data.error) return { ctx: null, error: data.error };
  return { ctx: data, error: null };
}

async function tools() {
  const { data, error } = await db.rpc("muster_engine_agent_tools");
  if (error) throw new Error(error.message);
  return (data as Array<Record<string, unknown>>).map((t) => ({ name: t.name, description: t.description, inputSchema: t.inputSchema, annotations: { scope: t.scope, readOnlyHint: t.scope === "read" } }));
}

async function callTool(ctx: unknown, name: string, args: Record<string, unknown>) {
  const { data, error } = await db.rpc("muster_engine_agent_call", { p_ctx: ctx, p_tool: name, p_args: args ?? {} });
  if (error) throw new Error(error.message);
  return data;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return json({}, 204);
  const url = new URL(req.url);

  if (req.method === "GET") {
    // Public catalog so an agent builder can inspect the tools before minting a key.
    try {
      return json({ name: "muster", version: "1.0.0", protocolVersion: PROTOCOL_VERSION, transport: "streamable-http",
        auth: { header: "x-muster-api-key", issue: "public.muster_create_api_key (Pro plan or super admin)" },
        endpoint: url.origin + url.pathname, tools: await tools() });
    } catch (e) { return json({ error: String(e) }, 500); }
  }
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  const { ctx, error: authErr } = await resolveKey(req);
  let body: Record<string, unknown> = {};
  try { body = await req.json(); } catch { body = {}; }
  const isRpc = body && body.jsonrpc === "2.0";

  if (!ctx) {
    return isRpc ? json(rpcError(body.id, -32001, "unauthorized: " + authErr), 401) : json({ ok: false, error: authErr }, 401);
  }

  // MCP JSON-RPC surface
  if (isRpc) {
    const method = String(body.method ?? "");
    const id = body.id;
    const params = (body.params ?? {}) as Record<string, unknown>;
    try {
      if (method === "initialize") {
        return json({ jsonrpc: "2.0", id, result: { protocolVersion: PROTOCOL_VERSION, capabilities: { tools: { listChanged: false } },
          serverInfo: { name: "muster", version: "1.0.0" },
          instructions: `You are connected to MUSTER website assurance as agent "${(ctx as { agent_name: string }).agent_name}". Every finding and SITREP claim carries evidence ids; cite them (E<id>, F<id>) when reporting to humans. Statuses reflect scanner evidence, not legal certification.` } });
      }
      if (method === "notifications/initialized" || method.startsWith("notifications/")) return new Response(null, { status: 202 });
      if (method === "ping") return json({ jsonrpc: "2.0", id, result: {} });
      if (method === "tools/list") return json({ jsonrpc: "2.0", id, result: { tools: await tools() } });
      if (method === "tools/call") {
        const name = String(params.name ?? "");
        const args = (params.arguments ?? {}) as Record<string, unknown>;
        try {
          const result = await callTool(ctx, name, args);
          return json({ jsonrpc: "2.0", id, result: { content: [{ type: "text", text: JSON.stringify(result) }], structuredContent: typeof result === "object" && result !== null && !Array.isArray(result) ? result : { result }, isError: false } });
        } catch (e) {
          return json({ jsonrpc: "2.0", id, result: { content: [{ type: "text", text: String(e) }], isError: true } });
        }
      }
      return json(rpcError(id, -32601, `method not found: ${method}`), 404);
    } catch (e) {
      return json(rpcError(id, -32603, String(e)), 500);
    }
  }

  // REST surface
  const tool = String(body.tool ?? url.searchParams.get("tool") ?? "");
  if (!tool) return json({ ok: false, error: "tool is required", tools: await tools() }, 400);
  try {
    const result = await callTool(ctx, tool, (body.args ?? {}) as Record<string, unknown>);
    return json({ ok: true, tool, agent: (ctx as { agent_name: string }).agent_name, result });
  } catch (e) {
    const msg = String((e as Error).message ?? e);
    return json({ ok: false, tool, error: msg }, pgStatus(msg));
  }
});
