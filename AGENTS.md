# CavScope Agent Integration

CavScope provides an AI agent gateway via MCP (Model Context Protocol) and REST APIs. Agents can query workspace data, generate narratives, and run autonomous workflows.

## Quick Start

### MCP Server

Connect any MCP-compatible client (Claude, Cursor, ChatGPT) to:

```
Protocol: MCP (JSON-RPC 2.0 over HTTP)
Endpoint: https://<project>.supabase.co/functions/v1/muster-agent
Auth: x-muster-api-key: mk_... (issued via public.muster_create_api_key)
```

**Capabilities:**
- `tools/list` — List all available tools
- `tools/call` — Execute a tool with arguments
- `initialize` — Get server info and discovery URLs
- `ping` — Health check

### REST Interface

Call tools directly via HTTP:

```bash
curl -X POST https://<project>.supabase.co/functions/v1/muster-agent \
  -H "x-muster-api-key: mk_..." \
  -H "content-type: application/json" \
  -d '{"tool": "list_findings", "args": {"website_id": 3}}'
```

Response:
```json
{
  "ok": true,
  "tool": "list_findings",
  "agent": "your-agent-name",
  "result": { ... }
}
```

## Discovery

### OpenAPI Schema

All tools and endpoints are documented in OpenAPI 3.1:

```
GET https://<project>.supabase.co/functions/v1/muster-agent/openapi.json
```

Agents use this to understand:
- Available tools (names, descriptions, input schemas)
- Authentication requirements
- REST and MCP interfaces
- Agent loop capabilities

### Tool Catalog

Public tool listing (no auth required):

```
GET https://<project>.supabase.co/functions/v1/muster-agent
```

Returns catalog with JSON Schema for each tool.

## Tools

Tool availability depends on workspace authorization. Common tools:

- **list_findings** — Query findings by website, status, category
- **get_finding** — Retrieve finding detail with evidence
- **list_websites** — Search scanned websites
- **ai_narrative** — Generate finding narrative via agentic loop
- Additional tools per workspace entitlements (see tool catalog)

## Agent Loop

The `ai_narrative` tool runs Claude in an agentic loop (max 5 steps):

1. Claude receives findings, tools, and a task
2. Claude calls tools as needed to gather context
3. Tool results feed back into the loop
4. Loop continues until Claude says "done" or max_steps reached

This enables multi-step reasoning, retrieval, and refinement within a single API call.

**Example:** Narrative generation that calls `get_finding` to pull evidence details, then `list_websites` to check related sites, then returns a synthesized narrative.

## Authentication

### API Key

Request an API key:
```sql
-- As a Pro plan owner or super admin:
SELECT public.muster_create_api_key('my-agent-name');
-- Returns: { api_key: 'mk_...', created_at: '...', expires_at: ... }
```

Keys are hashed at rest. Each key is scoped to the issuing organization.

### Header

Pass the key in:
```
x-muster-api-key: mk_...
```

Or as a Bearer token:
```
Authorization: Bearer mk_...
```

## Permissions

Every tool call is authorized by Postgres RLS:

- Agents can only access data within their organization
- Tool scopes (read-only vs. write) are enforced
- User roles and entitlements determine what each agent can do
- Authorization checks run before any model code executes

## Error Handling

### REST Errors

```json
{ "ok": false, "error": "tool not found", "tool": "unknown_tool" }
```

Status codes: 400 (bad request), 401 (unauthorized), 404 (not found), 500 (server error).

### MCP Errors

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "error": { "code": -32601, "message": "method not found: unknown_method" }
}
```

Standard JSON-RPC 2.0 error codes.

## Monitoring

- **Error monitoring** via Sentry (production deployments)
- **Rate limits** per API key (plan-dependent)
- **Logging** in Supabase function logs (debug/error level)

## Resources

- **OpenAPI Spec:** `GET /muster-agent/openapi.json`
- **Tool Catalog:** `GET /muster-agent`
- **CLAUDE.md:** Project-specific instructions for AI agents
- **Source:** `supabase/functions/muster-agent/index.ts`
