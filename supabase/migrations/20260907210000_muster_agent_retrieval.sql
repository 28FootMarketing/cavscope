-- Adds retrieval capability to muster-agent via pgvector semantic search.
-- Claude can now search findings and evidence by meaning, gather context,
-- and refine narratives with retrieved information. Enables multi-step
-- reasoning in the agentic loop.
--
-- Embeddings are generated on-demand via Claude's text-embedding-3-small
-- (8191-dim, efficient) when findings are created or evidence is captured.
-- Search returns ranked results with similarity scores.
--
-- Two new tools:
-- - search_findings: semantic search over finding titles and descriptions
-- - search_evidence: semantic search over evidence content
--
-- Both enforce org-scoped RLS and respect authorization.

create extension if not exists vector schema public;

-- Finding embeddings for semantic search
create table if not exists muster.finding_embeddings (
  id bigint primary key,
  finding_id bigint not null references muster.findings(id) on delete cascade,
  organization_id bigint not null,
  website_id bigint not null,
  chunk_text text not null,
  chunk_index int not null default 0,
  embedding public.vector(1536) not null,
  created_at timestamptz not null default now(),
  unique(finding_id, chunk_index)
);

create index if not exists idx_finding_embeddings_org on muster.finding_embeddings(organization_id);
create index if not exists idx_finding_embeddings_website on muster.finding_embeddings(website_id);
create index if not exists idx_finding_embeddings_vector on muster.finding_embeddings using ivfflat (embedding public.vector_cosine_ops) with (lists = 100);

-- Evidence embeddings for semantic search
create table if not exists muster.evidence_embeddings (
  id bigint primary key,
  evidence_id bigint not null references muster.evidences(id) on delete cascade,
  organization_id bigint not null,
  website_id bigint not null,
  chunk_text text not null,
  chunk_index int not null default 0,
  embedding public.vector(1536) not null,
  created_at timestamptz not null default now(),
  unique(evidence_id, chunk_index)
);

create index if not exists idx_evidence_embeddings_org on muster.evidence_embeddings(organization_id);
create index if not exists idx_evidence_embeddings_website on muster.evidence_embeddings(website_id);
create index if not exists idx_evidence_embeddings_vector on muster.evidence_embeddings using ivfflat (embedding public.vector_cosine_ops) with (lists = 100);

-- RLS policies for finding embeddings
alter table muster.finding_embeddings enable row level security;
create policy "org scope" on muster.finding_embeddings for select using (organization_id = auth.jwt()->>'organization_id'::bigint or (select auth.role() = 'service_role'));

-- RLS policies for evidence embeddings
alter table muster.evidence_embeddings enable row level security;
create policy "org scope" on muster.evidence_embeddings for select using (organization_id = auth.jwt()->>'organization_id'::bigint or (select auth.role() = 'service_role'));

-- Search findings by meaning (similarity search)
create or replace function muster.q_search_findings(p_website_id bigint, p_query_embedding public.vector, p_limit int = 10, p_threshold float = 0.6)
returns table(finding_id bigint, title text, category text, severity text, chunk_text text, similarity float)
language sql
stable
set search_path = ''
as $$
  select
    f.id,
    f.title,
    f.category,
    f.severity,
    fe.chunk_text,
    (1 - (fe.embedding <=> p_query_embedding))::float as similarity
  from muster.finding_embeddings fe
  join muster.findings f on f.id = fe.finding_id
  where fe.website_id = p_website_id
    and f.status in ('open', 'reopened')
    and (1 - (fe.embedding <=> p_query_embedding))::float >= p_threshold
  order by similarity desc
  limit p_limit;
$$;

-- Search evidence by meaning (similarity search)
create or replace function muster.q_search_evidence(p_website_id bigint, p_query_embedding public.vector, p_limit int = 10, p_threshold float = 0.6)
returns table(evidence_id bigint, finding_id bigint, chunk_text text, similarity float)
language sql
stable
set search_path = ''
as $$
  select
    e.id,
    e.finding_id,
    ee.chunk_text,
    (1 - (ee.embedding <=> p_query_embedding))::float as similarity
  from muster.evidence_embeddings ee
  join muster.evidences e on e.id = ee.evidence_id
  join muster.findings f on f.id = e.finding_id
  where ee.website_id = p_website_id
    and f.status in ('open', 'reopened')
    and (1 - (ee.embedding <=> p_query_embedding))::float >= p_threshold
  order by similarity desc
  limit p_limit;
$$;

-- Update agent_tools to include search tools
create or replace function muster.agent_tools()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_array(
    jsonb_build_object('name', 'list_websites', 'scope', 'read', 'description', 'List websites the agent can see with posture score, open findings, and latest scan.',
      'inputSchema', jsonb_build_object('type', 'object', 'properties', jsonb_build_object('organization_id', jsonb_build_object('type', 'integer', 'description', 'Required for platform-scoped keys.')))),
    jsonb_build_object('name', 'website_overview', 'scope', 'read', 'description', 'Full picture for one website: posture, open findings with evidence ids, compliance posture by law, brand, recent scans.',
      'inputSchema', jsonb_build_object('type', 'object', 'required', jsonb_build_array('website_id'), 'properties', jsonb_build_object('website_id', jsonb_build_object('type', 'integer')))),
    jsonb_build_object('name', 'list_findings', 'scope', 'read', 'description', 'Findings for a website filtered by status (open, reopened, resolved, accepted, false_positive).',
      'inputSchema', jsonb_build_object('type', 'object', 'required', jsonb_build_array('website_id'), 'properties', jsonb_build_object('website_id', jsonb_build_object('type', 'integer'), 'statuses', jsonb_build_object('type', 'array', 'items', jsonb_build_object('type', 'string'))))),
    jsonb_build_object('name', 'search_findings', 'scope', 'read', 'description', 'Semantic search over finding titles and descriptions. Returns most relevant open findings with similarity scores. Use this to find related issues or gather context.',
      'inputSchema', jsonb_build_object('type', 'object', 'required', jsonb_build_array('website_id', 'query'), 'properties', jsonb_build_object('website_id', jsonb_build_object('type', 'integer'), 'query', jsonb_build_object('type', 'string', 'description', 'Search terms or description of what you''re looking for'), 'limit', jsonb_build_object('type', 'integer', 'default', 10), 'threshold', jsonb_build_object('type', 'number', 'default', 0.6, 'description', 'Similarity threshold 0-1; lower = broader')))),
    jsonb_build_object('name', 'search_evidence', 'scope', 'read', 'description', 'Semantic search over captured evidence. Returns relevant evidence chunks with links to findings. Use this to verify claims or find supporting data.',
      'inputSchema', jsonb_build_object('type', 'object', 'required', jsonb_build_array('website_id', 'query'), 'properties', jsonb_build_object('website_id', jsonb_build_object('type', 'integer'), 'query', jsonb_build_object('type', 'string', 'description', 'Search terms or description of evidence you need'), 'limit', jsonb_build_object('type', 'integer', 'default', 10), 'threshold', jsonb_build_object('type', 'number', 'default', 0.6)))),
    jsonb_build_object('name', 'get_evidence', 'scope', 'read', 'description', 'Return one captured evidence row (headers, excerpt, hash) so a claim can be verified.',
      'inputSchema', jsonb_build_object('type', 'object', 'required', jsonb_build_array('evidence_id'), 'properties', jsonb_build_object('evidence_id', jsonb_build_object('type', 'integer')))),
    jsonb_build_object('name', 'latest_sitrep', 'scope', 'read', 'description', 'Latest SITREP for a website, with board report, plain English, citations, and markdown.',
      'inputSchema', jsonb_build_object('type', 'object', 'required', jsonb_build_array('website_id'), 'properties', jsonb_build_object('website_id', jsonb_build_object('type', 'integer')))),
    jsonb_build_object('name', 'get_sitrep', 'scope', 'read', 'description', 'A specific SITREP by id.',
      'inputSchema', jsonb_build_object('type', 'object', 'required', jsonb_build_array('sitrep_id'), 'properties', jsonb_build_object('sitrep_id', jsonb_build_object('type', 'integer')))),
    jsonb_build_object('name', 'compliance_posture', 'scope', 'read', 'description', 'Laws that apply to the organization''s jurisdiction, each with status derived from open scanner findings.',
      'inputSchema', jsonb_build_object('type', 'object', 'required', jsonb_build_array('website_id'), 'properties', jsonb_build_object('website_id', jsonb_build_object('type', 'integer')))),
    jsonb_build_object('name', 'jurisdiction_advisory', 'scope', 'read', 'description', 'Law advisory for a country and optional state/region code.',
      'inputSchema', jsonb_build_object('type', 'object', 'required', jsonb_build_array('country_code'), 'properties', jsonb_build_object('country_code', jsonb_build_object('type', 'string'), 'region_code', jsonb_build_object('type', 'string')))),
    jsonb_build_object('name', 'ai_narrative', 'scope', 'read',
      'description', 'AI-written executive narrative synthesizing a website''s open findings into a short, cited summary. Requires the ai_narrative flag to be enabled for the organization -- returns 403 if disabled. Every claim cites a finding id (F<id>) or evidence id (E<id>) from the data this tool assembles; the model never sees or invents anything outside it.',
      'inputSchema', jsonb_build_object('type', 'object', 'required', jsonb_build_array('website_id'),
        'properties', jsonb_build_object(
          'website_id', jsonb_build_object('type', 'integer'),
          'audience', jsonb_build_object('type', 'string', 'enum', jsonb_build_array('board', 'plain', 'technical'), 'description', 'Tone to write for. Defaults to board.')))),
    jsonb_build_object('name', 'request_scan', 'scope', 'scan', 'description', 'Queue a scan for a website now. Returns the scan id; results arrive within a few minutes.',
      'inputSchema', jsonb_build_object('type', 'object', 'required', jsonb_build_array('website_id'), 'properties', jsonb_build_object('website_id', jsonb_build_object('type', 'integer')))),
    jsonb_build_object('name', 'update_finding_status', 'scope', 'write', 'description', 'Set a finding to open, accepted, false_positive, or resolved with a note.',
      'inputSchema', jsonb_build_object('type', 'object', 'required', jsonb_build_array('finding_id', 'status'), 'properties', jsonb_build_object('finding_id', jsonb_build_object('type', 'integer'), 'status', jsonb_build_object('type', 'string'), 'note', jsonb_build_object('type', 'string')))),
    jsonb_build_object('name', 'promote_finding_to_risk', 'scope', 'write', 'description', 'Create a risk register entry (with evidence link) from a finding.',
      'inputSchema', jsonb_build_object('type', 'object', 'required', jsonb_build_array('finding_id'), 'properties', jsonb_build_object('finding_id', jsonb_build_object('type', 'integer')))));
$$;

-- Search tool authorization and execution
-- Called by muster-agent edge function, which handles embedding

create or replace function public.muster_engine_search_findings(
  p_ctx jsonb,
  p_website_id bigint,
  p_embedding public.vector,
  p_limit int = 10,
  p_threshold float = 0.6
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key_org bigint := nullif(p_ctx->>'organization_id', '')::bigint;
  v_org bigint;
begin
  -- Authorization: check scope and org
  if not ('admin' = any (array(select jsonb_array_elements_text(coalesce(p_ctx->'scopes', '[]'::jsonb)))) or
          'read' = any (array(select jsonb_array_elements_text(coalesce(p_ctx->'scopes', '[]'::jsonb))))) then
    raise exception 'key lacks the read scope' using errcode = '42501';
  end if;

  -- Org scope
  select w.organization_id into v_org from muster.websites w where w.id = p_website_id;
  if v_org is null then
    raise exception 'website not found' using errcode = '42704';
  end if;
  if v_key_org is not null and v_org <> v_key_org then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  -- Search and return
  return coalesce(
    jsonb_agg(jsonb_build_object(
      'finding_id', result.finding_id,
      'title', result.title,
      'category', result.category,
      'severity', result.severity,
      'chunk_text', result.chunk_text,
      'similarity', result.similarity
    ) order by result.similarity desc),
    '[]'::jsonb
  ) from muster.q_search_findings(p_website_id, p_embedding, p_limit, p_threshold) result;
end;
$$;

create or replace function public.muster_engine_search_evidence(
  p_ctx jsonb,
  p_website_id bigint,
  p_embedding public.vector,
  p_limit int = 10,
  p_threshold float = 0.6
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key_org bigint := nullif(p_ctx->>'organization_id', '')::bigint;
  v_org bigint;
begin
  -- Authorization: check scope and org
  if not ('admin' = any (array(select jsonb_array_elements_text(coalesce(p_ctx->'scopes', '[]'::jsonb)))) or
          'read' = any (array(select jsonb_array_elements_text(coalesce(p_ctx->'scopes', '[]'::jsonb))))) then
    raise exception 'key lacks the read scope' using errcode = '42501';
  end if;

  -- Org scope
  select w.organization_id into v_org from muster.websites w where w.id = p_website_id;
  if v_org is null then
    raise exception 'website not found' using errcode = '42704';
  end if;
  if v_key_org is not null and v_org <> v_key_org then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  -- Search and return
  return coalesce(
    jsonb_agg(jsonb_build_object(
      'evidence_id', result.evidence_id,
      'finding_id', result.finding_id,
      'chunk_text', result.chunk_text,
      'similarity', result.similarity
    ) order by result.similarity desc),
    '[]'::jsonb
  ) from muster.q_search_evidence(p_website_id, p_embedding, p_limit, p_threshold) result;
end;
$$;
