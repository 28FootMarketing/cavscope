-- muster_069: a tenant brings their own LLM.
--
-- WHAT THIS IS FOR. Until now there is one platform OpenRouter key in edge-function
-- env and one model, used by three things: the ai_narrative tool, the agent loop,
-- and embeddings. A client who does not want their findings reaching MUSTER's
-- inference account needs their own endpoint, and a client with a negotiated
-- provider contract wants to use it.
--
-- SCOPE, decided deliberately. This covers the ai_narrative tool and the agent
-- loop. It does NOT cover embeddings, which stay on MUSTER's key, because
-- finding_embeddings, doc_chunks and chunk embeddings are all pinned to
-- vector(1536): a tenant model with different dimensions breaks retrieval
-- outright, and one with the same dimensions silently poisons it, since new
-- vectors would not be comparable to the ones already stored. Changing a
-- tenant's embedding model means re-embedding their whole corpus, which is an
-- operation, not a setting. Say this to a client rather than glossing it.
--
-- NO SILENT FALLBACK. A tenant with no configuration gets no LLM at all -- the
-- deterministic SITREP generator, which is what every one of the 42 reports in
-- this database was produced by. The engine must never quietly fall back to
-- MUSTER's key for a tenant who has configured their own, because the entire
-- point of the feature is that their data does not go to our account. A broken
-- tenant key is a visible error, not a silent redirect.
--
-- THE KEY IS A CREDENTIAL FOR SOMEONE ELSE'S BILLABLE ACCOUNT. It goes in Vault,
-- it is readable only by the service role through muster_engine_llm_config(),
-- and nothing reachable from a browser ever returns it. muster_llm_config()
-- returns a four-character hint and nothing else, so the UI can show that a key
-- is set without being able to leak it.
--
-- A TENANT-SUPPLIED URL IS AN SSRF VECTOR. We fetch it from an edge function
-- carrying a bearer token, so a base_url pointing at a link-local or private
-- address turns this feature into a probe of our own infrastructure. The guard
-- below is the same shape as muster.is_valid_cta_destination(), which already
-- exists in this schema for exactly this class of problem, tightened: https
-- only, no mailto, and the private and link-local ranges refused by literal.
-- It is a CHECK constraint as well as an RPC validation, so a direct insert
-- cannot bypass it either.

create or replace function muster.is_valid_llm_endpoint(p_url text)
returns boolean
language sql
immutable
set search_path to ''
as $$
  select case
    when p_url is null or btrim(p_url) = '' then false
    when p_url !~* '^https://' then false
    else (
      select h <> ''
         and h !~ '[[:space:]]'
         -- Placeholder hosts, the same convention is_valid_cta_destination uses.
         and h not like 'your-%'
         and h !~ '(^|\.)example\.(com|net|org)$'
         and h !~ '\.(example|test|invalid|localhost)$'
         -- Loopback and "this host" by name.
         and h <> 'localhost'
         and h not like '%.localhost'
         and h <> '127.0.0.1'
         and h !~ '^127\.'
         and h <> '0.0.0.0'
         and h <> '[::1]'
         and h <> '::1'
         -- RFC 1918, and RFC 6598 carrier-grade NAT.
         and h !~ '^10\.'
         and h !~ '^192\.168\.'
         and h !~ '^172\.(1[6-9]|2[0-9]|3[01])\.'
         and h !~ '^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.'
         -- Link-local, which is where cloud instance metadata lives. This one
         -- is the reason the whole guard exists.
         and h !~ '^169\.254\.'
         and h not like '[fe80:%'
         and h not like '[fc%'
         and h not like '[fd%'
      from (select lower(coalesce(substring(p_url from '^https://([^/?#]+)'), '')) as h) t
    )
  end;
$$;

comment on function muster.is_valid_llm_endpoint(text) is
  'True if p_url is safe to use as a tenant-supplied LLM base URL: absolute https to a public host. Refuses loopback, RFC1918, CGNAT and link-local (169.254.x.x, where cloud instance metadata lives), because the edge function fetches this URL carrying a bearer token.';

create table if not exists muster.org_llm_config (
  organization_id bigint primary key references muster.organizations(id) on delete cascade,
  -- What the tenant calls this, for their own UI. Not used in any request.
  label           varchar(80),
  -- OpenAI-shaped only in v1. That covers OpenRouter, OpenAI, Azure, Together,
  -- Groq, vLLM and anything else speaking /chat/completions. Anthropic's native
  -- API is a different shape and is reached through an OpenAI-compatible
  -- endpoint or not at all; do not silently accept it and produce 400s.
  base_url        text not null,
  model           varchar(160) not null,
  -- vault.secrets id. The key itself is never in this table.
  secret_id       uuid not null,
  -- Last four characters, for the UI to show a key is set without leaking it.
  key_hint        varchar(8),
  enabled         boolean not null default true,
  -- Whether the last real call worked. A tenant key that expires must be
  -- visible rather than producing silent deterministic output forever.
  last_ok_at      timestamptz,
  last_error      text,
  last_error_at   timestamptz,
  created_by_id   bigint references muster.users(id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint org_llm_config_base_url_valid check (muster.is_valid_llm_endpoint(base_url))
);

comment on table muster.org_llm_config is
  'Per-tenant LLM endpoint for the ai_narrative tool and the agent loop. One row per organization, or none, in which case that tenant gets no LLM at all rather than MUSTER''s. Embeddings are never covered by this: they are pinned to vector(1536) and a model change would invalidate the stored corpus.';

create trigger org_llm_config_touch before update on muster.org_llm_config
  for each row execute function muster.touch_updated_at();

alter table muster.org_llm_config enable row level security;

-- No policy is created on purpose. Every read and write goes through the
-- SECURITY DEFINER RPCs below, which check the caller's role explicitly. RLS on
-- with no policy means a direct PostgREST read returns nothing, which is the
-- correct answer for a table whose every row points at a credential.
