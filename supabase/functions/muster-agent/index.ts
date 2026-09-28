import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { AI_NARRATIVE_SYSTEM_PROMPT } from "./prompt.ts";
import {
  buildNarrativeUserPrompt,
  parseNarrativeResponse,
  verifyNarrativeCitations,
  type NarrativeContext,
} from "./narrative.ts";
import {
  buildChatBody,
  buildChatHeaders,
  chatCompletionsUrl,
  isOpenRouter,
  LlmNotConfiguredError,
  readLlmConfig,
  summariseLlmError,
  type TenantLlm,
} from "./llm.ts";

// CavScope agent gateway. Makes every workspace usable by an AI agent or AI employee.
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
// TWO DIFFERENT CREDENTIALS, and the split is the whole of the BYO-LLM feature.
//
//   ai_narrative and the agent loop  ->  the TENANT's endpoint, model and key, from
//     muster.org_llm_config via muster_engine_llm_config_for_website(). A tenant with no
//     configuration gets NO llm: the call fails with an actionable message and that
//     organization stays on the deterministic SITREP generator. There is deliberately no
//     fallback to CavScope's key, because the point of the feature is that their findings do
//     not reach our inference account. A broken tenant key is a visible error, never a
//     silent redirect. See migrations 069/070/071 and docs/BACKEND.md.
//
//   search_* embeddings  ->  CavScope's own key, always. finding_embeddings, doc_chunks and
//     chunk embeddings are pinned to vector(1536); a tenant model with other dimensions
//     breaks retrieval and one with the same dimensions silently poisons it. Re-embedding a
//     corpus is an operation, not a setting. Say that to a client rather than glossing it.
//     Set CavScope's own:
//       supabase secrets set MUSTER_OPENROUTER_API_KEY=...   (the key named "muster-agent")
//     Falls back to the project-wide OPENROUTER_API_KEY when that is unset.

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const PROTOCOL_VERSION = "2025-06-18";

// CavScope's own OpenRouter credential. EMBEDDINGS ONLY -- see the header. Nothing
// model-facing on the narrative or agent-loop path may read this.
// Edge function secrets are project-wide, and
// this Supabase project is shared across every 28FS brand, so OPENROUTER_API_KEY is
// one value that CORA, AIVA, ROS, BRD, GFFH and s28 all draw against -- a spend cap
// hit by any one of them takes CavScope down too (it did, 2026-09-06). Prefer a
// CavScope-scoped key, fall back to the shared one so nothing breaks before it is set.
function openRouterKey(): string | undefined {
  return Deno.env.get("MUSTER_OPENROUTER_API_KEY") ?? Deno.env.get("OPENROUTER_API_KEY");
}

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

// A tenant with no LLM configured is not a server fault, and 500 would send an
// integrator looking for one. 409: the request is well formed and cannot be
// served until something about this organization changes.
function httpStatusFor(e: unknown): number {
  if (e instanceof LlmNotConfiguredError) return 409;
  return pgStatus(String((e as Error).message ?? e));
}

// Behind Supabase's edge proxy req.url arrives as http://, so url.protocol and
// url.origin advertise http:// in the OpenAPI servers[] block, the MCP discovery
// URLs and the catalog endpoint -- all of which agents read and then call.
// Trust x-forwarded-proto, default to https.
function publicOrigin(req: Request, url: URL): string {
  return `${req.headers.get("x-forwarded-proto") ?? "https"}://${url.host}`;
}

// The edge runtime also strips the /functions/v1 prefix before the request
// reaches the function, so url.pathname is "/muster-agent" -- everything built
// from it (OpenAPI servers[0].url, the MCP discovery urls, the catalog's
// endpoint) advertised a URL that 404s when an agent actually calls it.
// Verified live 2026-09-07: the catalog returned
// https://<project>.supabase.co/muster-agent. Put the prefix back when the
// runtime has taken it off.
function publicPath(url: URL): string {
  return url.pathname.startsWith("/functions/v1/")
    ? url.pathname
    : `/functions/v1/${url.pathname.replace(/^\/+/, "")}`;
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
  const baseUrl = `${publicOrigin(req, url)}${publicPath(url).replace(/\/openapi\.json$/, "")}`;
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
      title: "CavScope Agent API",
      version: "1.0.0",
      description:
        "AI agent gateway for CavScope website assurance. Provides MCP (JSON-RPC 2.0) and REST interfaces to query findings, generate narratives, and access workspace data.",
      contact: {
        name: "28 Foot Systems",
        url: "https://muster.partners",
      },
    },
    servers: [
      {
        url: baseUrl,
        description: "CavScope agent endpoint",
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

async function embedText(text: string): Promise<number[]> {
  const apiKey = openRouterKey();
  if (!apiKey) throw new Error("search requires MUSTER_OPENROUTER_API_KEY (or OPENROUTER_API_KEY) for embeddings");

  const res = await fetch("https://openrouter.ai/api/v1/embeddings", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "authorization": `Bearer ${apiKey}`,
      "http-referer": "https://muster.partners",
      "x-title": "CavScope search embedding",
    },
    body: JSON.stringify({
      model: "openai/text-embedding-3-small",
      input: text,
      encoding_format: "float",
    }),
    signal: AbortSignal.timeout(10000),
  });

  if (!res.ok) {
    const detail = await res.text().catch(() => "");
    throw new Error(`embedding failed (${res.status}): ${detail.slice(0, 300)}`);
  }

  const payload = await res.json();
  const embedding = payload?.data?.[0]?.embedding;
  if (!Array.isArray(embedding) || embedding.length === 0) {
    throw new Error("embedding returned no vector");
  }
  return embedding;
}

async function callSearchFindings(ctx: unknown, args: Record<string, unknown>): Promise<unknown> {
  const website_id = args.website_id as number;
  const query = args.query as string;
  const limit = (args.limit as number) || 10;
  const threshold = (args.threshold as number) || 0.6;

  if (!website_id || !query) {
    throw new Error("search_findings requires website_id and query");
  }

  // Embed the query
  const embedding = await embedText(query);

  // Search via SQL (convert embedding array to pgvector format)
  const { data, error } = await db.rpc("muster_engine_search_findings", {
    p_ctx: ctx,
    p_website_id: website_id,
    p_embedding: embedding,
    p_limit: limit,
    p_threshold: threshold,
  });

  if (error) throw new Error(error.message);
  return data;
}

async function callSearchEvidence(ctx: unknown, args: Record<string, unknown>): Promise<unknown> {
  const website_id = args.website_id as number;
  const query = args.query as string;
  const limit = (args.limit as number) || 10;
  const threshold = (args.threshold as number) || 0.6;

  if (!website_id || !query) {
    throw new Error("search_evidence requires website_id and query");
  }

  // Embed the query
  const embedding = await embedText(query);

  // Search via SQL
  const { data, error } = await db.rpc("muster_engine_search_evidence", {
    p_ctx: ctx,
    p_website_id: website_id,
    p_embedding: embedding,
    p_limit: limit,
    p_threshold: threshold,
  });

  if (error) throw new Error(error.message);
  return data;
}

async function callSearchDocs(ctx: unknown, args: Record<string, unknown>): Promise<unknown> {
  const query = args.query as string;
  const limit = (args.limit as number) || 8;
  const threshold = (args.threshold as number) || 0.5;

  if (!query) throw new Error("search_docs requires query");

  const embedding = await embedText(query);

  // No website_id: CavScope's documentation is not tenant data and is not scoped to a
  // site. Which documents come back IS scoped -- the shim decides from p_ctx whether
  // this key may see internal documentation, so a tenant key gets the rule catalog
  // and nothing about the infrastructure.
  const { data, error } = await db.rpc("muster_engine_search_docs", {
    p_ctx: ctx,
    p_embedding: embedding,
    p_limit: limit,
    p_threshold: threshold,
  });

  if (error) throw new Error(error.message);
  return data;
}

async function callTool(ctx: unknown, name: string, args: Record<string, unknown>) {
  // Tools that require special handling beyond callToolRaw
  if (name === "ai_narrative") {
    const context = await callToolRaw(ctx, name, args) as Record<string, unknown>;
    return await generateAiNarrative(ctx, context);
  }
  if (name === "search_findings") {
    return await callSearchFindings(ctx, args);
  }
  if (name === "search_evidence") {
    return await callSearchEvidence(ctx, args);
  }
  if (name === "search_docs") {
    return await callSearchDocs(ctx, args);
  }
  // All other tools: authorize via SQL and execute
  return await callToolRaw(ctx, name, args);
}

// Resolve the LLM of the organization that OWNS the website being narrated --
// not the organization on the API key. Those differ: a platform-scoped key
// (organization_id null) may narrate any site, and running that through
// CavScope's own account would send a tenant's findings to our inference provider
// through the one path built to stop exactly that. SQL maps website -> org ->
// vault, so this function never names an org id and cannot ask for the wrong
// tenant's credential.
async function resolveTenantLlm(websiteId: unknown, websiteLabel: string): Promise<TenantLlm> {
  const { data, error } = await db.rpc("muster_engine_llm_config_for_website", { p_website_id: websiteId });
  if (error) throw new Error(error.message);
  return readLlmConfig(data, websiteLabel);
}

// Best effort by design: a tenant whose key just worked must still get their
// narrative if this bookkeeping write fails.
async function recordLlmResult(organizationId: number, ok: boolean, error?: string): Promise<void> {
  try {
    await db.rpc("muster_engine_record_llm_result", { p_organization_id: organizationId, p_ok: ok, p_error: error ?? null });
  } catch { /* ignore */ }
}

async function runAgentLoop(ctx: unknown, llm: TenantLlm, systemPrompt: string, userPrompt: string, maxSteps = 5): Promise<{ messages: Array<Record<string, unknown>>; finalText: string }> {
  // Endpoint shaping, the OpenRouter-only body extension and error redaction
  // live in ./llm.ts so tests/agent exercises them; only the fetch is here.
  const endpoint = chatCompletionsUrl(llm.base_url);
  const openRouter = isOpenRouter(llm.base_url);

  // OpenRouter's /chat/completions is OpenAI-shaped. Tools go as
  // {type:"function", function:{name, description, parameters}}, NOT Anthropic's
  // {name, description, input_schema}.
  const toolList = await tools();
  const openaiTools = toolList.map((t) => ({
    type: "function",
    function: {
      name: t.name,
      description: t.description,
      parameters: t.inputSchema,
    },
  }));

  // Widened past {role, content}: assistant turns carry tool_calls and tool
  // turns carry tool_call_id.
  const messages: Array<Record<string, unknown>> = [
    { role: "user", content: userPrompt },
  ];

  for (let step = 0; step < maxSteps; step++) {
    let res: Response;
    try {
      res = await fetch(endpoint, {
        method: "POST",
        headers: buildChatHeaders(llm.api_key, openRouter, "CavScope AI agent loop"),
        body: JSON.stringify(buildChatBody({
          model: llm.model,
          systemPrompt,
          messages,
          tools: openaiTools,
          openRouter,
        })),
        signal: AbortSignal.timeout(20000),
      });
    } catch (e) {
      // The endpoint is named, because "could not reach the provider" is
      // unanswerable to an operator who configured a URL we then never echo.
      throw new Error(`agent loop could not reach ${endpoint}: ${(e as Error).message ?? e}`);
    }
    if (!res.ok) {
      const detail = await res.text().catch(() => "");
      // Redacted: a provider that quotes the presented credential in its 401
      // body would otherwise put a live key into last_error, which
      // muster_llm_config returns to a browser.
      throw new Error(`agent loop call failed (${summariseLlmError({ status: res.status, detail: detail.slice(0, 300), apiKey: llm.api_key })})`);
    }

    const payload = await res.json();
    const choice = payload?.choices?.[0];
    if (!choice) throw new Error("agent loop returned no choice");

    const assistantMessage = choice.message;
    if (!assistantMessage) throw new Error("agent loop returned no message");

    // OpenAI shape, not Anthropic's: message.content is a string (null when the
    // model only called tools), tool calls live in message.tool_calls, and the
    // reason is finish_reason ("stop" | "tool_calls" | "length"). Reading
    // stop_reason and treating content as an array of typed blocks silently
    // produced an empty finalText on every call, which then failed JSON.parse.
    const toolCalls: Array<{ id?: string; function?: { name?: string; arguments?: string } }> =
      Array.isArray(assistantMessage.tool_calls) ? assistantMessage.tool_calls : [];
    const contentText = typeof assistantMessage.content === "string" ? assistantMessage.content : "";

    messages.push({
      role: "assistant",
      content: assistantMessage.content ?? null,
      ...(toolCalls.length > 0 ? { tool_calls: assistantMessage.tool_calls } : {}),
    });

    if (toolCalls.length === 0) {
      // No tools requested, so this turn is the answer regardless of how the
      // provider labelled finish_reason. Truncation is the one case where the
      // text is not trustworthy and must not be parsed as a whole answer.
      if (choice.finish_reason === "length") {
        throw new Error("agent loop response was truncated (finish_reason: length)");
      }
      return { messages, finalText: contentText };
    }

    // Tool results are their own role:"tool" messages keyed by tool_call_id,
    // not tool_result blocks inside a user message.
    for (const call of toolCalls) {
      const name = call?.function?.name ?? "";
      let args: Record<string, unknown> = {};
      try {
        args = call?.function?.arguments ? JSON.parse(call.function.arguments) : {};
      } catch {
        args = {};
      }
      let resultText: string;
      try {
        resultText = JSON.stringify(await callTool(ctx, name, args));
      } catch (e) {
        resultText = `Error: ${(e as Error).message}`;
      }
      messages.push({ role: "tool", tool_call_id: call.id, content: resultText });
    }
  }

  // Max steps exceeded
  throw new Error(`agent loop exceeded maximum steps (${maxSteps})`);
}

async function generateAiNarrative(ctx: unknown, context: Record<string, unknown>) {
  const label = context.website_url ? `${context.website_name} (${context.website_url})` : `website ${context.website_id}`;
  // Throws LlmNotConfiguredError when this tenant has no endpoint, which is a
  // normal state and not a fault: they stay on the deterministic generator.
  // Nothing below runs, so no CavScope credential is anywhere on this path.
  const llm = await resolveTenantLlm(context.website_id, label);

  let verified;
  try {
    const { finalText } = await runAgentLoop(ctx, llm, AI_NARRATIVE_SYSTEM_PROMPT, buildNarrativeUserPrompt(context as NarrativeContext), 5);

    // Parsing and citation verification are in ./narrative.ts so the eval suite
    // (evals/ai-narrative) exercises this exact code rather than a copy that
    // drifts. Everything model-facing stays here; everything checkable is there.
    const parsed = parseNarrativeResponse(finalText);
    verified = verifyNarrativeCitations(context as NarrativeContext, parsed);
  } catch (e) {
    // A parse failure is recorded alongside a transport failure on purpose. To
    // the operator reading last_error both mean "my model did not produce a
    // narrative", and recording only the transport half would leave a model
    // that returns prose instead of JSON looking perfectly healthy forever.
    await recordLlmResult(llm.organization_id, false, summariseLlmError({ message: String((e as Error).message ?? e), apiKey: llm.api_key }));
    throw e;
  }
  await recordLlmResult(llm.organization_id, true);

  return {
    website_id: context.website_id,
    audience: context.audience,
    ...verified,
    // The tenant's model, named in the output. A board-facing narrative should
    // say which model wrote it, and after this change that is no longer a
    // constant.
    model: llm.model,
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
        endpoint: publicOrigin(req, url) + publicPath(url), tools: await tools() });
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
        const baseUrl = `${publicOrigin(req, url)}${publicPath(url).replace(/\/?$/, "")}`;
        return json({ jsonrpc: "2.0", id, result: { protocolVersion: PROTOCOL_VERSION, capabilities: { tools: { listChanged: false } },
          serverInfo: { name: "muster", version: "1.0.0" },
          instructions: `You are connected to CavScope website assurance as agent "${(ctx as { agent_name: string }).agent_name}". Every finding and SITREP claim carries evidence ids; cite them (E<id>, F<id>) when reporting to humans. Statuses reflect scanner evidence, not legal certification.`,
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
    return json({ ok: false, tool, error: String((e as Error).message ?? e) }, httpStatusFor(e));
  }
});
