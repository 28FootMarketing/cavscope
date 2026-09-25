// Tenant-supplied LLM: the pure half. Everything here is a function of its
// arguments -- no fetch, no database, no Deno globals -- so tests/agent
// exercises the shipped code rather than a copy of it. index.ts does the I/O.
//
// Why this is a module and not four lines inline in runAgentLoop: the request
// this builds goes to a URL a customer typed, carrying a credential that bills
// a customer's account, and the error text it produces is read back by a
// browser. Each of those three is a place to get it wrong quietly, and each is
// pinned by a test here.

export type TenantLlm = {
  organization_id: number;
  base_url: string;
  model: string;
  api_key: string;
};

/** No row in muster.org_llm_config. Not an error in the system, a state of the tenant. */
export class LlmNotConfiguredError extends Error {}

/** The stored base_url does not survive re-validation at call time. */
export class LlmEndpointError extends Error {}

// ---------------------------------------------------------------------------
// Endpoint
// ---------------------------------------------------------------------------

/**
 * The JS half of muster.is_valid_llm_endpoint (migration 069). Same literals,
 * same order, deliberately duplicated.
 *
 * The SQL runs as a CHECK constraint, so a row cannot be written with a bad
 * URL. This runs at call time, which is a different question: the value has
 * been at rest in a table since it was written, and this function is what
 * decides where an edge function points a request carrying a bearer token. A
 * guard that is only enforced on the write path is enforced at the wrong end.
 *
 * Change one and you must change the other; tests/agent/llm.test.ts walks the
 * same case list the migration header describes.
 */
export function isSafeLlmEndpoint(url: string): boolean {
  const raw = String(url ?? "").trim();
  if (!/^https:\/\//i.test(raw)) return false;

  const host = (raw.match(/^https:\/\/([^/?#]+)/i)?.[1] ?? "").toLowerCase();
  if (!host || /\s/.test(host)) return false;

  // Placeholder hosts, the convention is_valid_cta_destination already uses.
  if (host.startsWith("your-")) return false;
  if (/(^|\.)example\.(com|net|org)$/.test(host)) return false;
  if (/\.(example|test|invalid|localhost)$/.test(host)) return false;

  // Loopback and "this host" by name.
  if (host === "localhost" || host.endsWith(".localhost")) return false;
  if (/^127\./.test(host)) return false;
  if (host === "0.0.0.0" || host === "[::1]" || host === "::1") return false;

  // RFC 1918, and RFC 6598 carrier-grade NAT.
  if (/^10\./.test(host)) return false;
  if (/^192\.168\./.test(host)) return false;
  if (/^172\.(1[6-9]|2[0-9]|3[01])\./.test(host)) return false;
  if (/^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\./.test(host)) return false;

  // Link-local, which is where cloud instance metadata lives. This one is the
  // reason the whole guard exists.
  if (/^169\.254\./.test(host)) return false;
  if (host.startsWith("[fe80:") || host.startsWith("[fc") || host.startsWith("[fd")) return false;

  return true;
}

/**
 * Where to POST a chat completion, given a tenant's base_url.
 *
 * Accepts either the API base (`https://api.openai.com/v1`) or the full
 * endpoint, because both are what people paste, and appending to the latter
 * would produce a 404 the operator would read as "CavScope cannot reach my
 * provider" rather than "I pasted one path segment too many".
 */
export function chatCompletionsUrl(baseUrl: string): string {
  const trimmed = String(baseUrl ?? "").trim().replace(/\/+$/, "");
  if (!isSafeLlmEndpoint(trimmed)) {
    throw new LlmEndpointError(
      "the configured LLM endpoint is not an absolute https URL on a public host; re-save it in the workspace",
    );
  }
  return /\/chat\/completions$/i.test(trimmed) ? trimmed : `${trimmed}/chat/completions`;
}

/** OpenRouter takes extensions nobody else does. See buildChatBody. */
export function isOpenRouter(baseUrl: string): boolean {
  const host = (String(baseUrl ?? "").match(/^https:\/\/([^/?#]+)/i)?.[1] ?? "").toLowerCase();
  return host === "openrouter.ai" || host.endsWith(".openrouter.ai");
}

// ---------------------------------------------------------------------------
// Request
// ---------------------------------------------------------------------------

export function buildChatHeaders(apiKey: string, openRouter: boolean, title: string): Record<string, string> {
  const headers: Record<string, string> = {
    "content-type": "application/json",
    "authorization": `Bearer ${apiKey}`,
  };
  // Attribution headers OpenRouter reads and everyone else ignores. Sent only
  // where they mean something, so a tenant's request carries nothing about
  // CavScope that their provider did not ask for.
  if (openRouter) {
    headers["http-referer"] = "https://muster.partners";
    headers["x-title"] = title;
  }
  return headers;
}

/**
 * The chat-completions body.
 *
 * `reasoning` is an OpenRouter extension, and this is the line that made the
 * module worth writing: OpenAI and Azure reject an unrecognised top-level
 * parameter with a 400, so the body that has always worked against the
 * platform's OpenRouter key would have failed every call against a tenant's
 * own OpenAI account. The failure would have surfaced as "your key does not
 * work", which is the wrong thing to tell a customer about a working key.
 */
export function buildChatBody(input: {
  model: string;
  systemPrompt: string;
  messages: Array<Record<string, unknown>>;
  tools: Array<Record<string, unknown>>;
  openRouter: boolean;
  maxTokens?: number;
  temperature?: number;
}): Record<string, unknown> {
  const body: Record<string, unknown> = {
    model: input.model,
    max_tokens: input.maxTokens ?? 2000,
    temperature: input.temperature ?? 0.3,
    messages: [{ role: "system", content: input.systemPrompt }, ...input.messages],
  };
  if (input.tools.length > 0) body.tools = input.tools;
  if (input.openRouter) body.reasoning = { enabled: false };
  return body;
}

// ---------------------------------------------------------------------------
// Reading the config back
// ---------------------------------------------------------------------------

/**
 * Turn what muster_engine_llm_config_for_website returned into a TenantLlm, or
 * raise LlmNotConfiguredError.
 *
 * The not-configured message names the setting and who can change it, because
 * it is the one error here a customer sees and can act on alone.
 */
export function readLlmConfig(payload: unknown, websiteLabel: string): TenantLlm {
  const p = (payload ?? {}) as Record<string, unknown>;
  if (p.configured !== true) {
    throw new LlmNotConfiguredError(
      `no LLM is configured for the organization that owns ${websiteLabel}. ` +
      "CavScope does not fall back to its own inference account: an organization executive sets an endpoint, " +
      "model and API key in the workspace, or this organization stays on the deterministic generator.",
    );
  }
  const org = Number(p.organization_id);
  const base_url = String(p.base_url ?? "");
  const model = String(p.model ?? "");
  const api_key = String(p.api_key ?? "");
  if (!Number.isFinite(org) || !base_url || !model || !api_key) {
    throw new LlmEndpointError("the stored LLM configuration is incomplete; re-save it in the workspace");
  }
  return { organization_id: org, base_url, model, api_key };
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/**
 * Strip a secret out of text before it is stored or shown.
 *
 * muster_engine_record_llm_result writes last_error, and muster_llm_config
 * returns last_error to a browser. A provider that echoes the presented
 * credential in its 401 body -- or one of our own messages built from the
 * request -- would otherwise put a live key on a page, through the one path in
 * this feature that was built to keep keys off pages.
 */
export function redactSecret(text: string, secret: string): string {
  let out = String(text ?? "");
  const s = String(secret ?? "");
  if (s.length >= 8) out = out.split(s).join("[redacted]");
  // Any other bearer token in the text, including one for a key we were not
  // given -- a provider quoting a different credential is still a credential.
  return out.replace(/Bearer\s+[A-Za-z0-9._\-]{8,}/gi, "Bearer [redacted]");
}

/**
 * A short, storable account of why a call failed, for last_error.
 *
 * Capped at the column's 500 characters on this side too, so what is written is
 * what was meant rather than whatever survived a left(). Status is kept because
 * 401 and 429 are different conversations with a customer: one is a dead key,
 * the other is a working key over its quota.
 */
export function summariseLlmError(input: {
  status?: number;
  detail?: string;
  message?: string;
  apiKey: string;
}): string {
  const head = input.status ? `HTTP ${input.status}` : (input.message ?? "call failed");
  const body = input.status ? (input.detail ?? "") : (input.detail ?? "");
  const joined = body ? `${head}: ${body}` : head;
  return redactSecret(joined, input.apiKey).slice(0, 500);
}
