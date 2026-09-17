import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  buildChatBody,
  buildChatHeaders,
  chatCompletionsUrl,
  isOpenRouter,
  isSafeLlmEndpoint,
  LlmEndpointError,
  LlmNotConfiguredError,
  readLlmConfig,
  redactSecret,
  summariseLlmError,
} from "../../supabase/functions/muster-agent/llm.ts";

const AGENT = readFileSync(new URL("../../supabase/functions/muster-agent/index.ts", import.meta.url), "utf8");
const GUARD_SQL = readFileSync(new URL("../../supabase/migrations/20260917073710_muster_069_tenant_llm_config.sql", import.meta.url), "utf8");
const FOR_WEBSITE_SQL = readFileSync(new URL("../../supabase/migrations/20260917080637_muster_071_llm_config_for_website.sql", import.meta.url), "utf8");

// ---------------------------------------------------------------------------
// The SSRF guard, and its parity with the SQL
// ---------------------------------------------------------------------------

// Each row is [url, allowed, the SQL literal that decides it]. The third column
// is what keeps the two copies honest: the JS guard in llm.ts and the SQL guard
// in muster.is_valid_llm_endpoint are separate implementations of one rule, and
// a case removed from one silently would otherwise pass here.
const ENDPOINTS: Array<[string, boolean, string | null]> = [
  ["https://openrouter.ai/api/v1", true, null],
  ["https://api.openai.com/v1", true, null],
  ["https://llm.acme-corp.co.uk/v1", true, null],

  ["http://api.openai.com/v1", false, "^https://"],
  ["", false, null],
  ["ftp://api.openai.com", false, "^https://"],

  ["https://localhost/v1", false, "'localhost'"],
  ["https://api.localhost/v1", false, "%.localhost"],
  ["https://127.0.0.1:8080/v1", false, "^127\\."],
  ["https://127.1.2.3/v1", false, "^127\\."],
  ["https://0.0.0.0/v1", false, "'0.0.0.0'"],
  ["https://[::1]/v1", false, "'[::1]'"],

  ["https://10.0.0.5/v1", false, "^10\\."],
  ["https://192.168.1.10/v1", false, "^192\\.168\\."],
  ["https://172.16.0.1/v1", false, "^172\\.(1[6-9]|2[0-9]|3[01])\\."],
  ["https://172.31.255.254/v1", false, "^172\\.(1[6-9]|2[0-9]|3[01])\\."],
  ["https://100.64.0.1/v1", false, "^100\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\."],

  // The reason the whole guard exists: EC2/GCP instance metadata.
  ["https://169.254.169.254/latest/meta-data", false, "^169\\.254\\."],
  ["https://[fe80::1]/v1", false, "[fe80:"],
  ["https://[fc00::1]/v1", false, "[fc"],
  ["https://[fd12:3456::1]/v1", false, "[fd"],

  ["https://your-provider.example/v1", false, "your-%"],
  ["https://api.example.com/v1", false, "example\\.(com|net|org)$"],
  ["https://api.invalid/v1", false, "(example|test|invalid|localhost)$"],
];

test("the endpoint guard accepts public https and refuses everything else", () => {
  for (const [url, allowed] of ENDPOINTS) {
    assert.equal(isSafeLlmEndpoint(url), allowed, `${url || "(empty)"} should be ${allowed ? "allowed" : "refused"}`);
  }
});

test("172.32 and 100.128 are outside the private ranges and stay allowed", () => {
  // The boundary cases the range regexes exist to get right. Refusing these
  // would block real public addresses.
  assert.equal(isSafeLlmEndpoint("https://172.32.0.1/v1"), true);
  assert.equal(isSafeLlmEndpoint("https://172.15.0.1/v1"), true);
  assert.equal(isSafeLlmEndpoint("https://100.128.0.1/v1"), true);
  assert.equal(isSafeLlmEndpoint("https://100.63.0.1/v1"), true);
});

test("every literal the JS guard refuses on is still in the SQL guard", () => {
  // Migration 069's CHECK constraint and llm.ts must refuse the same things.
  // If someone relaxes the SQL, this fails rather than leaving the write path
  // open and the call path closed (or worse, the other way round).
  for (const [, , literal] of ENDPOINTS) {
    if (!literal) continue;
    assert.ok(GUARD_SQL.includes(literal), `muster.is_valid_llm_endpoint no longer contains ${literal}`);
  }
});

// ---------------------------------------------------------------------------
// Endpoint shaping
// ---------------------------------------------------------------------------

test("a base URL becomes a chat-completions endpoint", () => {
  assert.equal(chatCompletionsUrl("https://openrouter.ai/api/v1"), "https://openrouter.ai/api/v1/chat/completions");
  assert.equal(chatCompletionsUrl("https://api.openai.com/v1/"), "https://api.openai.com/v1/chat/completions");
  assert.equal(chatCompletionsUrl("  https://api.groq.com/openai/v1  "), "https://api.groq.com/openai/v1/chat/completions");
});

test("a base URL that already names the endpoint is not doubled", () => {
  // People paste the full URL. Appending would 404, and the operator would
  // read that as MUSTER being unable to reach their provider.
  assert.equal(
    chatCompletionsUrl("https://api.openai.com/v1/chat/completions"),
    "https://api.openai.com/v1/chat/completions",
  );
});

test("an unsafe stored base URL is refused at call time, not only at write time", () => {
  // The CHECK constraint guards the write. This guards the request, which is
  // the end that actually carries a bearer token.
  assert.throws(() => chatCompletionsUrl("https://169.254.169.254/v1"), LlmEndpointError);
  assert.throws(() => chatCompletionsUrl("http://api.openai.com/v1"), LlmEndpointError);
});

test("OpenRouter is recognised by host, not by substring", () => {
  assert.equal(isOpenRouter("https://openrouter.ai/api/v1"), true);
  assert.equal(isOpenRouter("https://gateway.openrouter.ai/v1"), true);
  assert.equal(isOpenRouter("https://api.openai.com/v1"), false);
  // A host that merely mentions it must not unlock OpenRouter-only body fields.
  assert.equal(isOpenRouter("https://openrouter.ai.evil.example.net/v1"), false);
});

// ---------------------------------------------------------------------------
// Request shaping
// ---------------------------------------------------------------------------

const BODY = {
  model: "gpt-4.1",
  systemPrompt: "SYS",
  messages: [{ role: "user", content: "hello" }],
  tools: [{ type: "function", function: { name: "list_findings" } }],
};

test("the OpenRouter-only reasoning field is not sent to other providers", () => {
  // The regression this module was written for. OpenAI and Azure reject an
  // unrecognised top-level parameter with a 400, so the body that has always
  // worked against MUSTER's OpenRouter key would have failed every call
  // against a tenant's own OpenAI account -- and been reported to them as a
  // bad key.
  const openai = buildChatBody({ ...BODY, openRouter: false });
  assert.equal("reasoning" in openai, false);

  const openrouter = buildChatBody({ ...BODY, openRouter: true });
  assert.deepEqual(openrouter.reasoning, { enabled: false });
});

test("the body carries the tenant's model and the system prompt first", () => {
  const body = buildChatBody({ ...BODY, openRouter: false });
  assert.equal(body.model, "gpt-4.1");
  const messages = body.messages as Array<Record<string, unknown>>;
  assert.equal(messages[0].role, "system");
  assert.equal(messages[0].content, "SYS");
  assert.equal(messages[1].content, "hello");
});

test("an empty tool list is omitted rather than sent as []", () => {
  const body = buildChatBody({ ...BODY, tools: [], openRouter: false });
  assert.equal("tools" in body, false);
});

test("OpenRouter attribution headers go only to OpenRouter", () => {
  const plain = buildChatHeaders("sk-tenant-key", false, "MUSTER AI agent loop");
  assert.equal(plain.authorization, "Bearer sk-tenant-key");
  assert.equal("http-referer" in plain, false);
  assert.equal("x-title" in plain, false);

  const or = buildChatHeaders("sk-tenant-key", true, "MUSTER AI agent loop");
  assert.equal(or["http-referer"], "https://muster.partners");
  assert.equal(or["x-title"], "MUSTER AI agent loop");
});

// ---------------------------------------------------------------------------
// Reading the config
// ---------------------------------------------------------------------------

test("no configuration is an actionable state, not a fallback", () => {
  let err: unknown;
  try {
    readLlmConfig({ configured: false, organization_id: 17 }, "Acme (https://acme.example.net)");
  } catch (e) { err = e; }

  assert.ok(err instanceof LlmNotConfiguredError);
  const msg = (err as Error).message;
  // It must say who fixes it and what happens meanwhile, and it must say that
  // MUSTER does not substitute its own account -- that sentence is the feature.
  assert.match(msg, /does not fall back/i);
  assert.match(msg, /deterministic/i);
  assert.match(msg, /executive/i);
});

test("a configured tenant resolves to its own endpoint, model and key", () => {
  const llm = readLlmConfig(
    { configured: true, organization_id: 17, base_url: "https://api.openai.com/v1", model: "gpt-4.1", api_key: "sk-abc12345" },
    "Acme",
  );
  assert.deepEqual(llm, {
    organization_id: 17,
    base_url: "https://api.openai.com/v1",
    model: "gpt-4.1",
    api_key: "sk-abc12345",
  });
});

test("a half-written configuration fails loudly instead of calling nothing", () => {
  assert.throws(
    () => readLlmConfig({ configured: true, organization_id: 17, base_url: "https://api.openai.com/v1", model: "gpt-4.1" }, "Acme"),
    LlmEndpointError,
  );
});

// ---------------------------------------------------------------------------
// Errors are stored and shown, so they must not carry the key
// ---------------------------------------------------------------------------

test("a provider that echoes the key does not get it written to last_error", () => {
  // muster_engine_record_llm_result writes last_error, and muster_llm_config
  // returns last_error to a browser. This is the last stop before a live key
  // lands on a page.
  const key = "sk-live-9f2a77bc";
  const detail = `{"error":{"message":"Incorrect API key provided: ${key}"}}`;
  const summary = summariseLlmError({ status: 401, detail, apiKey: key });

  assert.equal(summary.includes(key), false);
  assert.match(summary, /HTTP 401/);
  assert.match(summary, /\[redacted\]/);
});

test("any bearer token is redacted, including one we were not given", () => {
  const out = redactSecret("upstream said: Authorization: Bearer sk-someone-elses-key", "sk-ours-1234");
  assert.equal(out.includes("sk-someone-elses-key"), false);
  assert.match(out, /Bearer \[redacted\]/);
});

test("the status is kept, because 401 and 429 are different conversations", () => {
  assert.match(summariseLlmError({ status: 429, detail: "rate limited", apiKey: "sk-abc12345" }), /HTTP 429/);
  assert.match(summariseLlmError({ message: "connection reset", apiKey: "sk-abc12345" }), /connection reset/);
});

test("a stored error cannot overflow the 500-character column", () => {
  const summary = summariseLlmError({ status: 500, detail: "x".repeat(4000), apiKey: "sk-abc12345" });
  assert.ok(summary.length <= 500, `got ${summary.length}`);
});

// ---------------------------------------------------------------------------
// Wiring: the properties that make the feature true rather than present
// ---------------------------------------------------------------------------

test("the narrative and agent-loop path never reads MUSTER's own key", () => {
  // openRouterKey() is embeddings-only. One call site, inside embedText.
  const calls = AGENT.match(/(?<!function )openRouterKey\(\)/g) ?? [];
  assert.equal(calls.length, 1, "openRouterKey() should be called exactly once, by embedText");

  const embedText = AGENT.slice(AGENT.indexOf("async function embedText"), AGENT.indexOf("async function callSearchFindings"));
  assert.ok(embedText.includes("openRouterKey()"), "the one call site should be embedText");

  const loop = AGENT.slice(AGENT.indexOf("async function runAgentLoop"), AGENT.indexOf("async function generateAiNarrative"));
  assert.equal(loop.includes("openRouterKey"), false, "runAgentLoop must not reach for MUSTER's key");
  assert.equal(loop.includes("openrouter.ai"), false, "runAgentLoop must not hardcode a provider");
});

test("the tenant is resolved from the website, never from the API key", () => {
  // The org on an API key is not necessarily the org that owns the site: a
  // platform-scoped key may narrate any tenant's website. Keying off the key
  // would have found no config there and invited a fallback to MUSTER's
  // account -- silently, for a tenant who had configured their own.
  assert.ok(AGENT.includes("muster_engine_llm_config_for_website"));
  assert.equal(AGENT.includes("muster_engine_llm_config\""), false, "the edge function must not name an org id itself");

  const narrative = AGENT.slice(AGENT.indexOf("async function generateAiNarrative"));
  assert.ok(narrative.includes("resolveTenantLlm(context.website_id"));
  assert.equal(/ctx[^\n]*organization_id/.test(narrative), false, "the narrative path must not read organization_id off ctx");
});

test("the reported model is the tenant's, not a build-time constant", () => {
  assert.equal(AGENT.includes("OPENROUTER_MODEL"), false, "the platform model constant should be gone");
  const narrative = AGENT.slice(AGENT.indexOf("async function generateAiNarrative"));
  assert.match(narrative, /model:\s*llm\.model/);
});

test("both outcomes of a call are recorded, so a dead tenant key is visible", () => {
  const narrative = AGENT.slice(AGENT.indexOf("async function generateAiNarrative"));
  assert.match(narrative, /recordLlmResult\(llm\.organization_id,\s*false/);
  assert.match(narrative, /recordLlmResult\(llm\.organization_id,\s*true\)/);
});

test("the website-scoped credential read is revoked from anon and authenticated by name", () => {
  // Supabase's default privileges grant EXECUTE on every new public function to
  // both roles, and `revoke ... from public` does not undo it. This function
  // returns a decrypted tenant key.
  assert.match(
    FOR_WEBSITE_SQL,
    /revoke all on function public\.muster_engine_llm_config_for_website\(bigint\) from public, anon, authenticated;/,
  );
  assert.match(FOR_WEBSITE_SQL, /grant execute on function public\.muster_engine_llm_config_for_website\(bigint\) to service_role;/);
  assert.ok(FOR_WEBSITE_SQL.includes("has_function_privilege('anon'"));
  assert.ok(FOR_WEBSITE_SQL.includes("has_function_privilege('authenticated'"));
});
