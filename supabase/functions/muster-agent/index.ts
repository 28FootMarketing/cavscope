import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { AI_NARRATIVE_SYSTEM_PROMPT } from "./prompt.ts";

// MUSTER agent gateway. Makes every workspace usable by an AI agent or AI employee.
//
// Auth: header  x-muster-api-key: mk_...   (issued by public.muster_create_api_key, hashed at rest)
// Two surfaces on the same URL:
//   1. MCP (Streamable HTTP, stateless JSON-RPC 2.0): initialize, ping, tools/list, tools/call
//      Point any MCP client at https://<project>.supabase.co/functions/v1/muster-agent with the header above.
//   2. REST: POST { "tool": "list_findings", "args": { "website_id": 3 } }  ->  { "ok": true, "result": ... }
//      GET  /muster-agent  ->  tool catalog (JSON Schema per tool)
// All authorization and org scoping is enforced in SQL (public.muster_engine_agent_call), including
// for ai_narrative below -- its context (findings, evidence ids, the org's ai_narrative flag check)
// comes from that same RPC. Only the model call itself happens here, since Postgres can't make it.
//
// ai_narrative requires the OPENROUTER_API_KEY secret (supabase secrets set OPENROUTER_API_KEY=...).
// Model defaults to OPENROUTER_MODEL if set, else anthropic/claude-sonnet-5 (confirmed live on
// OpenRouter's catalog) -- override via that env var to point at a different Claude version.

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const PROTOCOL_VERSION = "2025-06-18";
const OPENROUTER_MODEL = Deno.env.get("OPENROUTER_MODEL") ?? "anthropic/claude-sonnet-5";

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

async function generateOpenAPISchema(req: Request) {
  const url = new URL(req.url);
  const baseUrl = `${url.protocol}//${url.host}${url.pathname.replace(/\/openapi\.json$/, "")}`;
  const toolList = await tools();

  // Build POST /muster-agent request body schema (tool call)
  const toolCallProperties: Record<string, unknown> = {
    tool: {
      type: "string",
      enum: toolList.map((t) => t.name),
      description: "The tool name to call",
    },
    args: {
      type: "object",
      description: "Tool arguments (schema depends on tool)",
    },
  };

  const schema: Record<string, unknown> = {
    openapi: "3.1.0",
    info: {
      title: "MUSTER Agent API",
      version: "1.0.0",
      description:
        "AI agent gateway for MUSTER website assurance. Provides MCP (JSON-RPC 2.0) and REST interfaces to query findings, generate narratives, and access workspace data.",
      contact: {
        name: "28 Foot Systems",
        url: "https://muster.28footsystems.com",
      },
    },
    servers: [
      {
        url: baseUrl,
        description: "MUSTER agent endpoint",
      },
    ],
    paths: {
      "/": {
        get: {
          summary: "Get tool catalog",
          description:
            "Returns list of available tools with their schemas. Public endpoint, no auth required.",
          tags: ["Discovery"],
          responses: {
            "200": {
              description: "Tool catalog",
              content: {
                "application/json": {
                  schema: {
                    type: "object",
                    properties: {
                      name: { type: "string" },
                      version: { type: "string" },
                      protocolVersion: { type: "string" },
                      transport: { type: "string" },
                      auth: {
                        type: "object",
                        properties: {
                          header: { type: "string" },
                          issue: { type: "string" },
                        },
                      },
                      tools: {
                        type: "array",
                        items: {
                          type: "object",
                          properties: {
                            name: { type: "string" },
                            description: { type: "string" },
                            inputSchema: { type: "object" },
                          },
                        },
                      },
                    },
                  },
                },
              },
            },
          },
        },
        post: {
          summary: "Call tool or MCP request",
          description:
            "Dual-mode endpoint: accepts REST tool calls or MCP JSON-RPC 2.0 requests. Detect mode by presence of jsonrpc field.",
          tags: ["Tools", "MCP"],
          security: [{ apiKey: [] }],
          requestBody: {
            required: true,
            content: {
              "application/json": {
                schema: {
                  oneOf: [
                    {
                      type: "object",
                      title: "REST Tool Call",
                      properties: toolCallProperties,
                      required: ["tool"],
                      description: "Direct tool invocation",
                    },
                    {
                      type: "object",
                      title: "MCP JSON-RPC 2.0",
                      properties: {
                        jsonrpc: { const: "2.0" },
                        id: { type: ["string", "number", "null"] },
                        method: {
                          type: "string",
                          enum: ["initialize", "ping", "tools/list", "tools/call"],
                        },
                        params: { type: "object" },
                      },
                      required: ["jsonrpc", "method"],
                      description: "MCP protocol request",
                    },
                  ],
                },
              },
            },
          },
          responses: {
            "200": {
              description: "Success (REST or MCP response)",
              content: {
                "application/json": {
                  schema: {
                    oneOf: [
                      {
                        type: "object",
                        properties: {
                          ok: { type: "boolean" },
                          tool: { type: "string" },
                          agent: { type: "string" },
                          result: { type: "object" },
                        },
                        description: "REST tool call response",
                      },
                      {
                        type: "object",
                        properties: {
                          jsonrpc: { const: "2.0" },
                          id: { type: ["string", "number", "null"] },
                          result: { type: "object" },
                        },
                        description: "MCP JSON-RPC 2.0 response",
                      },
                    ],
                  },
                },
              },
            },
            "400": {
              description: "Bad request",
            },
            "401": {
              description: "Unauthorized (missing or invalid API key)",
            },
            "404": {
              description: "Tool not found (REST) or method not found (MCP)",
            },
            "500": {
              description: "Server error",
            },
          },
        },
      },
      "/openapi.json": {
        get: {
          summary: "Get OpenAPI schema",
          description: "Returns this OpenAPI 3.1 schema for agent discovery.",
          tags: ["Discovery"],
          responses: {
            "200": {
              description: "OpenAPI schema",
              content: {
                "application/json": {
                  schema: { type: "object" },
                },
              },
            },
          },
        },
      },
    },
    components: {
      securitySchemes: {
        apiKey: {
          type: "apiKey",
          in: "header",
          name: "x-muster-api-key",
          description:
            "API key issued by public.muster_create_api_key. Prefix: mk_. Also accepted as Authorization Bearer token.",
        },
      },
    },
    tags: [
      {
        name: "Discovery",
        description: "Public endpoints for discovering API capabilities",
      },
      {
        name: "Tools",
        description: "Call tools via REST interface",
      },
      {
        name: "MCP",
        description: "MCP (Model Context Protocol) JSON-RPC 2.0 interface",
      },
    ],
    "x-muster": {
      toolCount: toolList.length,
      tools: toolList.map((t) => ({
        name: t.name,
        description: t.description,
        scope: (t.annotations as Record<string, unknown>)?.scope,
        schema: t.inputSchema,
      })),
      capabilities: {
        agentLoop: true,
        streaming: false,
        maxSteps: 5,
      },
    },
  };

  return json(schema);
}

async function callToolRaw(ctx: unknown, name: string, args: Record<string, unknown>) {
  const { data, error } = await db.rpc("muster_engine_agent_call", { p_ctx: ctx, p_tool: name, p_args: args ?? {} });
  if (error) throw new Error(error.message);
  return data;
}

async function callTool(ctx: unknown, name: string, args: Record<string, unknown>) {
  // ai_narrative's SQL branch does the auth/org/flag check and returns model
  // context (not a final answer) -- the model call only happens once that
  // context comes back clean, same as every other tool's authorization path.
  if (name === "ai_narrative") {
    const context = await callToolRaw(ctx, name, args) as Record<string, unknown>;
    return await generateAiNarrative(ctx, context);
  }
  return await callToolRaw(ctx, name, args);
}

async function runAgentLoop(ctx: unknown, systemPrompt: string, userPrompt: string, maxSteps = 5): Promise<{ messages: Array<{ role: string; content: unknown }>; finalText: string }> {
  const apiKey = Deno.env.get("OPENROUTER_API_KEY");
  if (!apiKey) throw new Error("agent loop requires OPENROUTER_API_KEY");

  // Fetch tool definitions in Claude format
  const toolList = await tools();
  const claudeTools = toolList.map((t) => ({
    name: t.name,
    description: t.description,
    input_schema: t.inputSchema,
  }));

  const messages: Array<{ role: string; content: unknown }> = [
    { role: "user", content: userPrompt },
  ];

  for (let step = 0; step < maxSteps; step++) {
    let res: Response;
    try {
      res = await fetch("https://openrouter.ai/api/v1/chat/completions", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "authorization": `Bearer ${apiKey}`,
          "http-referer": "https://muster.28footsystems.com",
          "x-title": "MUSTER AI agent loop",
        },
        body: JSON.stringify({
          model: OPENROUTER_MODEL,
          max_tokens: 2000,
          temperature: 0.3,
          reasoning: { enabled: false },
          tools: claudeTools,
          messages: [
            { role: "system", content: systemPrompt },
            ...messages,
          ],
        }),
        signal: AbortSignal.timeout(20000),
      });
    } catch (e) {
      throw new Error(`agent loop call failed to reach OpenRouter: ${(e as Error).message ?? e}`);
    }
    if (!res.ok) {
      const detail = await res.text().catch(() => "");
      throw new Error(`agent loop call failed (${res.status}): ${detail.slice(0, 300)}`);
    }

    const payload = await res.json();
    const choice = payload?.choices?.[0];
    if (!choice) throw new Error("agent loop returned no choice");

    const assistantMessage = choice.message;
    if (!assistantMessage) throw new Error("agent loop returned no message");

    // Add assistant response to messages
    messages.push({
      role: "assistant",
      content: assistantMessage.content ?? [],
    });

    // Check stop reason
    if (choice.stop_reason === "end_turn") {
      // Extract final text content from the response
      const finalText = (Array.isArray(assistantMessage.content) ? assistantMessage.content : [])
        .filter((c: { type?: string }) => c?.type === "text")
        .map((c: { text?: string }) => c.text || "")
        .join("");
      return { messages, finalText };
    }

    // If tool_use, execute tools and add results
    if (choice.stop_reason === "tool_use" && Array.isArray(assistantMessage.content)) {
      const toolResults: Array<{ type: string; tool_use_id: string; content: string }> = [];
      let hasToolCalls = false;

      for (const block of assistantMessage.content) {
        if (block.type === "tool_use") {
          hasToolCalls = true;
          try {
            const toolResult = await callTool(ctx, block.name, block.input);
            toolResults.push({
              type: "tool_result",
              tool_use_id: block.id,
              content: JSON.stringify(toolResult),
            });
          } catch (e) {
            toolResults.push({
              type: "tool_result",
              tool_use_id: block.id,
              content: `Error: ${(e as Error).message}`,
            });
          }
        }
      }

      if (hasToolCalls) {
        messages.push({
          role: "user",
          content: toolResults,
        });
      } else {
        // No tool calls in the content, stop looping
        const finalText = (Array.isArray(assistantMessage.content) ? assistantMessage.content : [])
          .filter((c: { type?: string }) => c?.type === "text")
          .map((c: { text?: string }) => c.text || "")
          .join("");
        return { messages, finalText };
      }
    } else if (choice.stop_reason !== "tool_use") {
      // Stop reason is neither tool_use nor end_turn, return what we have
      const finalText = (Array.isArray(assistantMessage.content) ? assistantMessage.content : [])
        .filter((c: { type?: string }) => c?.type === "text")
        .map((c: { text?: string }) => c.text || "")
        .join("");
      return { messages, finalText };
    }
  }

  // Max steps exceeded
  throw new Error(`agent loop exceeded maximum steps (${maxSteps})`);
}

async function generateAiNarrative(ctx: unknown, context: Record<string, unknown>) {
  const userPrompt = [
    `Website: ${context.website_name} (${context.website_url})`,
    `Organization: ${context.organization_name}`,
    `Posture: ${context.posture_score}/100 (${context.posture_band})`,
    `Audience: ${context.audience}`,
    "",
    "Open findings (JSON array -- cite each entry's finding_id as F<id> and each id in its evidence_ids as E<id>):",
    JSON.stringify(context.findings ?? []),
  ].join("\n");

  const { finalText } = await runAgentLoop(ctx, AI_NARRATIVE_SYSTEM_PROMPT, userPrompt, 5);

  let parsed: unknown;
  try { parsed = JSON.parse(finalText); } catch { throw new Error("ai narrative model did not return valid JSON"); }
  const result = parsed as { headline?: unknown; narrative?: unknown; citations?: unknown; confidence?: unknown };
  if (typeof result.headline !== "string" || typeof result.narrative !== "string" || !Array.isArray(result.citations)) {
    throw new Error("ai narrative model returned an unexpected shape");
  }

  // Cross-check every citation against the ids the model was actually given.
  const allowed = new Set<string>();
  for (const f of (context.findings as Array<Record<string, unknown>> | undefined) ?? []) {
    if (f.finding_id !== undefined) allowed.add(`F${f.finding_id}`);
    for (const e of (f.evidence_ids as unknown[] | undefined) ?? []) allowed.add(`E${e}`);
  }
  const seen = new Set<string>();
  const citations: string[] = [];
  const unverified: string[] = [];
  for (const c of result.citations) {
    const token = String(c).trim().toUpperCase();
    if (!/^[FE]\d+$/.test(token) || seen.has(token)) continue;
    seen.add(token);
    (allowed.has(token) ? citations : unverified).push(token);
  }
  const confidence = unverified.length ? "low" : (typeof result.confidence === "string" ? result.confidence : "unknown");

  return {
    website_id: context.website_id,
    audience: context.audience,
    headline: result.headline,
    narrative: result.narrative,
    citations,
    unverified_citations: unverified,
    confidence,
    model: OPENROUTER_MODEL,
    generated_at: new Date().toISOString(),
  };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return json({}, 204);
  const url = new URL(req.url);

  if (req.method === "GET") {
    // Public OpenAPI schema
    if (url.pathname.endsWith("/openapi.json")) {
      try {
        return await generateOpenAPISchema(req);
      } catch (e) { return json({ error: String(e) }, 500); }
    }
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
        const baseUrl = `${url.protocol}//${url.host}${url.pathname.replace(/\/?$/, "")}`;
        return json({ jsonrpc: "2.0", id, result: { protocolVersion: PROTOCOL_VERSION, capabilities: { tools: { listChanged: false } },
          serverInfo: { name: "muster", version: "1.0.0" },
          instructions: `You are connected to MUSTER website assurance as agent "${(ctx as { agent_name: string }).agent_name}". Every finding and SITREP claim carries evidence ids; cite them (E<id>, F<id>) when reporting to humans. Statuses reflect scanner evidence, not legal certification.`,
          discovery: { openapi: `${baseUrl}/openapi.json`, catalog: baseUrl } } });
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
