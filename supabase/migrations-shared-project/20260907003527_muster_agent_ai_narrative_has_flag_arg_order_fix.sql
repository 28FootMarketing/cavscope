-- Fixes a bug in 20260907003416_muster_agent_ai_narrative.sql: muster.has_flag
-- takes (p_org bigint, p_key text), not (p_key, p_org) as that migration
-- assumed. Caught immediately by testing the new ai_narrative branch live
-- (42883: function muster.has_flag(unknown, bigint) does not exist) before
-- this ever shipped to an agent.

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
      if not muster.has_flag(v_org, 'ai_narrative') then
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
