-- Adds the ai_narrative tool to the muster-agent MCP/REST surface: an
-- AI-written executive synthesis of a website's open findings, grounded in
-- real scanner data. Postgres can't call an LLM, so this migration only adds
-- the tool's catalog entry and its authorization/context branch (mirroring
-- every other website-scoped tool's org check) plus the pre-existing
-- ai_narrative feature-flag gate; the model call itself lives in the
-- muster-agent Edge Function (supabase/functions/muster-agent/index.ts),
-- which calls this same RPC to get its authorized context before calling
-- OpenRouter.
--
-- ai_narrative (muster.feature_flags) is currently kill_switch = true, so
-- this tool returns 403 "ai narrative is disabled for this organization"
-- for every org until an operator turns it on.

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

create or replace function public.muster_engine_agent_call(p_ctx jsonb, p_tool text, p_args jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key_org bigint := nullif(p_ctx->>'organization_id', '')::bigint;
  v_agent bigint := (p_ctx->>'agent_id')::bigint;
  v_scopes text[] := array(select jsonb_array_elements_text(coalesce(p_ctx->'scopes', '[]'::jsonb)));
  v_org bigint;
  v_website bigint;
  v_need text;
begin
  select t->>'scope' into v_need from jsonb_array_elements(muster.agent_tools()) t where t->>'name' = p_tool;
  if v_need is null then raise exception 'unknown tool %', p_tool using errcode = '22023'; end if;
  if not ('admin' = any (v_scopes) or v_need = 'read' or v_need = any (v_scopes)) then
    raise exception 'key lacks the % scope', v_need using errcode = '42501';
  end if;

  if p_tool = 'list_websites' then
    v_org := coalesce(v_key_org, nullif(p_args->>'organization_id', '')::bigint);
    if v_org is null then raise exception 'organization_id is required for platform keys' using errcode = '22023'; end if;
    if v_key_org is not null and v_org <> v_key_org then raise exception 'forbidden' using errcode = '42501'; end if;
    return (select coalesce(jsonb_agg(muster.q_website_summary(w.id) order by w.created_at), '[]'::jsonb) from muster.websites w where w.organization_id = v_org);
  elsif p_tool = 'jurisdiction_advisory' then
    return muster.q_jurisdiction_advisory(p_args->>'country_code', p_args->>'region_code', true);
  elsif p_tool in ('website_overview','list_findings','latest_sitrep','compliance_posture','request_scan','ai_narrative') then
    v_website := nullif(p_args->>'website_id', '')::bigint;
    v_org := muster.website_org(v_website);
    if v_org is null then raise exception 'website not found' using errcode = 'P0002'; end if;
    if v_key_org is not null and v_org <> v_key_org then raise exception 'forbidden' using errcode = '42501'; end if;
    if p_tool = 'website_overview' then return muster.q_website_overview(v_website);
    elsif p_tool = 'list_findings' then
      return muster.q_findings(v_website, case when jsonb_typeof(p_args->'statuses') = 'array' and jsonb_array_length(p_args->'statuses') > 0
        then array(select jsonb_array_elements_text(p_args->'statuses')) else array['open','reopened'] end);
    elsif p_tool = 'latest_sitrep' then return muster.q_latest_sitrep(v_website);
    elsif p_tool = 'compliance_posture' then return muster.q_compliance_posture(v_website);
    elsif p_tool = 'ai_narrative' then
      if not muster.has_flag('ai_narrative', v_org) then
        raise exception 'ai narrative is disabled for this organization' using errcode = '42501';
      end if;
      return jsonb_build_object(
        'website_id', v_website,
        'audience', coalesce(nullif(p_args->>'audience', ''), 'board'),
        'organization_name', (select o.name from muster.organizations o where o.id = v_org),
        'website_name', (select w.name from muster.websites w where w.id = v_website),
        'website_url', (select w.url from muster.websites w where w.id = v_website),
        'posture_score', muster.posture_score(v_website),
        'posture_band', muster.posture_band(muster.posture_score(v_website)),
        'findings', (
          select coalesce(jsonb_agg(jsonb_build_object(
            'finding_id', fi.id, 'severity', fi.severity, 'title', fi.title,
            'plain_english', r.plain_english, 'remediation', r.remediation,
            'evidence_ids', (select coalesce(jsonb_agg(fe.evidence_id order by fe.evidence_id), '[]'::jsonb)
                             from muster.finding_evidence fe where fe.finding_id = fi.id)
          ) order by muster.severity_rank(fi.severity), fi.last_seen_at desc), '[]'::jsonb)
          from (
            select * from muster.findings
            where website_id = v_website and status in ('open','reopened')
            order by muster.severity_rank(severity), last_seen_at desc
            limit 15
          ) fi
          join muster.scan_rules r on r.rule_id = fi.rule_id
        )
      );
    else return muster.do_request_scan(v_website, null, v_agent, 'api');
    end if;
  elsif p_tool = 'get_sitrep' then
    select organization_id into v_org from muster.sitreps where id = nullif(p_args->>'sitrep_id', '')::bigint;
    if v_org is null then raise exception 'sitrep not found' using errcode = 'P0002'; end if;
    if v_key_org is not null and v_org <> v_key_org then raise exception 'forbidden' using errcode = '42501'; end if;
    return muster.q_sitrep((p_args->>'sitrep_id')::bigint);
  elsif p_tool = 'get_evidence' then
    select organization_id into v_org from muster.scan_evidence where id = nullif(p_args->>'evidence_id', '')::bigint;
    if v_org is null then raise exception 'evidence not found' using errcode = 'P0002'; end if;
    if v_key_org is not null and v_org <> v_key_org then raise exception 'forbidden' using errcode = '42501'; end if;
    return muster.q_evidence((p_args->>'evidence_id')::bigint);
  elsif p_tool in ('update_finding_status','promote_finding_to_risk') then
    select organization_id into v_org from muster.findings where id = nullif(p_args->>'finding_id', '')::bigint;
    if v_org is null then raise exception 'finding not found' using errcode = 'P0002'; end if;
    if v_key_org is not null and v_org <> v_key_org then raise exception 'forbidden' using errcode = '42501'; end if;
    if p_tool = 'update_finding_status' then
      return muster.do_update_finding_status((p_args->>'finding_id')::bigint, p_args->>'status', p_args->>'note', null, v_agent);
    else
      return muster.do_promote_finding((p_args->>'finding_id')::bigint, null, v_agent);
    end if;
  end if;
  raise exception 'unhandled tool %', p_tool using errcode = '22023';
end;
$$;
