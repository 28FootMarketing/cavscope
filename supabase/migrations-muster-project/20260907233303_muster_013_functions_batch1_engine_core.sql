-- MUSTER function layer, batch 1 of 3: the four largest bodies, copied from the
-- live catalog on mgtmqucaldkaxvxglguw (not replayed from repo history, which
-- has drifted from what was actually applied).
--
-- check_function_bodies is off because muster.agent_tools() is LANGUAGE sql and
-- would otherwise be parsed at CREATE time, and because these bodies reference
-- public.muster_* shims that do not exist on this project yet.
set check_function_bodies = off;

CREATE OR REPLACE FUNCTION muster.generate_sitrep(p_scan_id bigint)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v         record;
  v_score   integer;
  v_band    text;
  v_open    integer; v_crit integer; v_high integer; v_med integer; v_low integer; v_info integer;
  v_primary bigint;
  v_top     jsonb := '[]'::jsonb;
  v_claims  jsonb := '[]'::jsonb;
  v_plain   jsonb := '[]'::jsonb;
  v_cites   jsonb := '[]'::jsonb;
  v_evidx   jsonb;
  v_open_ids bigint[];
  v_md      text;
  v_headline text;
  v_version integer;
  v_id      bigint;
  f         record;
  i         integer := 0;
  c         integer := 0;
  v_ev_ids  bigint[];
  v_cite    text;
begin
  select s.*, w.name as website_name, w.url as website_url, o.name as org_name
  into v
  from muster.scans s
  join muster.websites w on w.id = s.website_id
  join muster.organizations o on o.id = w.organization_id
  where s.id = p_scan_id;
  if not found or v.status <> 'complete' then
    raise exception 'scan % is not complete', p_scan_id;
  end if;

  v_score := muster.posture_score(v.website_id);
  v_band := muster.posture_band(v_score);

  select count(*), count(*) filter (where severity='critical'), count(*) filter (where severity='high'),
         count(*) filter (where severity='medium'), count(*) filter (where severity='low'), count(*) filter (where severity='info'),
         coalesce(array_agg(id), '{}')
  into v_open, v_crit, v_high, v_med, v_low, v_info, v_open_ids
  from muster.findings where website_id = v.website_id and status in ('open','reopened');

  select id into v_primary from muster.scan_evidence
  where scan_id = p_scan_id and kind = 'http_response' order by id limit 1;

  -- Claim helper pattern: every claim carries finding_ids and evidence_ids.
  c := c + 1;
  v_claims := v_claims || jsonb_build_object('id', 'C'||c,
    'text', format('Overall website assurance posture is %s of 100 (%s).', v_score, v_band),
    'finding_ids', to_jsonb(v_open_ids), 'evidence_ids', to_jsonb(array_remove(array[v_primary], null)));
  c := c + 1;
  v_claims := v_claims || jsonb_build_object('id', 'C'||c,
    'text', format('The homepage responded with HTTP %s in %s ms from %s.', coalesce(v.http_status::text,'no response'), coalesce(v.response_ms::text,'n/a'), coalesce(v.final_url, v.target_url)),
    'finding_ids', '[]'::jsonb, 'evidence_ids', to_jsonb(array_remove(array[v_primary], null)));
  c := c + 1;
  v_claims := v_claims || jsonb_build_object('id', 'C'||c,
    'text', format('%s open findings: %s critical, %s high, %s medium, %s low, %s informational.', v_open, v_crit, v_high, v_med, v_low, v_info),
    'finding_ids', to_jsonb(v_open_ids), 'evidence_ids', '[]'::jsonb);
  c := c + 1;
  v_claims := v_claims || jsonb_build_object('id', 'C'||c,
    'text', format('This scan added %s findings, reopened %s, and resolved %s compared with the previous state.',
      coalesce(v.summary->>'new','0'), coalesce(v.summary->>'reopened','0'), coalesce(v.summary->>'resolved','0')),
    'finding_ids', '[]'::jsonb, 'evidence_ids', '[]'::jsonb);

  for f in
    select fi.id, fi.rule_id, fi.severity, fi.title, fi.detail, fi.page_url, fi.location, fi.confidence, fi.status,
           r.category, r.remediation, r.plain_english, r.framework_refs,
           coalesce((select array_agg(fe.evidence_id order by fe.evidence_id) from muster.finding_evidence fe where fe.finding_id = fi.id), '{}') as ev_ids
    from muster.findings fi join muster.scan_rules r on r.rule_id = fi.rule_id
    where fi.website_id = v.website_id and fi.status in ('open','reopened')
    order by muster.severity_rank(fi.severity), fi.last_seen_at desc, fi.id
    limit 12
  loop
    i := i + 1;
    v_top := v_top || jsonb_build_object('rank', i, 'finding_id', f.id, 'rule_id', f.rule_id, 'category', f.category,
      'severity', f.severity, 'status', f.status, 'title', f.title, 'detail', f.detail, 'page_url', f.page_url,
      'location', f.location, 'confidence', f.confidence, 'remediation', f.remediation,
      'framework_refs', f.framework_refs, 'evidence_ids', to_jsonb(f.ev_ids));
    c := c + 1;
    v_claims := v_claims || jsonb_build_object('id', 'C'||c,
      'text', format('%s (%s): %s', f.title, f.severity, f.detail),
      'finding_ids', to_jsonb(array[f.id]), 'evidence_ids', to_jsonb(f.ev_ids));
    v_plain := v_plain || jsonb_build_object('id', 'P'||i, 'finding_id', f.id,
      'text', f.plain_english || ' Fix: ' || f.remediation,
      'evidence_ids', to_jsonb(f.ev_ids));
  end loop;

  select coalesce(jsonb_agg(jsonb_build_object('evidence_id', e.id, 'kind', e.kind, 'url', e.url,
           'http_status', e.http_status, 'sha256', e.sha256, 'captured_at', e.captured_at) order by e.id), '[]'::jsonb)
  into v_evidx
  from muster.scan_evidence e where e.scan_id = p_scan_id;

  select coalesce(jsonb_agg(jsonb_build_object('claim_id', x->>'id', 'finding_ids', x->'finding_ids', 'evidence_ids', x->'evidence_ids')), '[]'::jsonb)
  into v_cites from jsonb_array_elements(v_claims) x;

  v_headline := format('%s: posture %s/100 (%s), %s open findings, %s critical', v.website_name, v_score, v_band, v_open, v_crit);

  -- Markdown rendering with inline citations [F<finding>] [E<evidence>].
  v_md := format(E'# SITREP: %s\n\nOrganization: %s\nTarget: %s\nScan: #%s completed %s (engine %s)\nPrepared by MUSTER. Every statement below cites a finding [F] or captured evidence [E] row.\n\n## Board Report\n\n',
    v.website_name, v.org_name, v.target_url, p_scan_id, to_char(v.finished_at at time zone 'UTC', 'YYYY-MM-DD HH24:MI UTC'), coalesce(v.engine_version,'n/a'));
  for f in select x from jsonb_array_elements(v_claims) x loop
    v_cite := '';
    select string_agg(distinct '[F'||y||']', '') into v_cite from jsonb_array_elements_text(f.x->'finding_ids') y;
    v_md := v_md || '- ' || (f.x->>'text') || ' ' || coalesce(v_cite,'');
    select string_agg('[E'||y||']', '') into v_cite from jsonb_array_elements_text(f.x->'evidence_ids') y;
    v_md := v_md || coalesce(v_cite,'') || E'\n';
  end loop;
  v_md := v_md || E'\n## Plain English\n\n';
  if jsonb_array_length(v_plain) = 0 then
    v_md := v_md || E'No open findings. Keep scanning on schedule so this stays true.\n';
  end if;
  for f in select x from jsonb_array_elements(v_plain) x loop
    select string_agg('[E'||y||']', '') into v_cite from jsonb_array_elements_text(f.x->'evidence_ids') y;
    v_md := v_md || '- ' || (f.x->>'text') || ' [F' || (f.x->>'finding_id') || ']' || coalesce(v_cite,'') || E'\n';
  end loop;
  v_md := v_md || E'\n## Evidence Index\n\n| Evidence | Kind | URL | HTTP | SHA-256 |\n|---|---|---|---|---|\n';
  for f in select x from jsonb_array_elements(v_evidx) x loop
    v_md := v_md || format('| E%s | %s | %s | %s | %s |', f.x->>'evidence_id', f.x->>'kind', f.x->>'url', coalesce(f.x->>'http_status','n/a'), left(coalesce(f.x->>'sha256',''), 12)) || E'\n';
  end loop;

  update muster.sitreps set status = 'superseded' where website_id = v.website_id and status = 'final';
  select coalesce(max(version), 0) + 1 into v_version from muster.sitreps where scan_id = p_scan_id;

  insert into muster.sitreps (organization_id, website_id, scan_id, version, status, posture_score, posture_band, headline,
    sections, citations, content_md, content_sha256)
  values (v.organization_id, v.website_id, p_scan_id, v_version, 'final', v_score, v_band, left(v_headline, 300),
    jsonb_build_object(
      'scan', jsonb_build_object('scan_id', p_scan_id, 'target_url', v.target_url, 'final_url', v.final_url,
        'started_at', v.started_at, 'finished_at', v.finished_at, 'http_status', v.http_status, 'response_ms', v.response_ms,
        'engine_version', v.engine_version, 'summary', v.summary),
      'board_report', jsonb_build_object('headline', v_headline, 'posture_score', v_score, 'posture_band', v_band,
        'open', v_open, 'critical', v_crit, 'high', v_high, 'medium', v_med, 'low', v_low, 'info', v_info, 'claims', v_claims),
      'plain_english', jsonb_build_object('items', v_plain),
      'top_findings', v_top,
      'evidence_index', v_evidx),
    v_cites, v_md, encode(sha256(convert_to(v_md, 'utf8')), 'hex'))
  returning id into v_id;

  insert into muster.activity_events (organization_id, entity_type, entity_id, action, detail)
  values (v.organization_id, 'sitrep', v_id, 'SITREP generated', v_headline);

  return v_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION muster.test_retrieval_contract()
 RETURNS TABLE(test text, passed boolean, detail text)
 LANGUAGE plpgsql
 SET search_path TO 'public', 'muster', 'pg_temp'
AS $function$
declare
  v_site bigint; v_org bigint; v_emb public.vector;
  v_ev_site bigint; v_ev_emb public.vector;
  v_n int; v_distinct int; v_sim double precision; v_bad int;
  v_unscoped boolean; v_reachable boolean;
begin
  select fe.website_id, fe.embedding into v_site, v_emb
    from muster.finding_embeddings fe order by fe.finding_id limit 1;
  select w.organization_id into v_org from muster.websites w where w.id = v_site;
  select ee.website_id, ee.embedding into v_ev_site, v_ev_emb
    from muster.evidence_embeddings ee
    join muster.finding_evidence fev on fev.evidence_id = ee.evidence_id
    join muster.findings f on f.id = fev.finding_id and f.status in ('open','reopened')
    order by ee.evidence_id limit 1;

  if v_emb is null then
    return query select 'fixtures_available', false, 'no finding embeddings; cannot run retrieval contract';
    return;
  end if;
  return query select 'fixtures_available', true, format('website %s, org %s', v_site, v_org);

  begin
    select count(*) into v_n from pg_proc p
      cross join lateral unnest(coalesce(p.proconfig, '{}')) cfg
     where cfg = 'search_path="public, muster"';
    return query select 'search_path_well_formed', v_n = 0,
      case when v_n = 0 then 'no malformed search_path settings'
           else format('%s function(s) still quote the whole list as one identifier', v_n) end;
  exception when others then return query select 'search_path_well_formed', false, sqlerrm; end;

  begin
    select count(*) into v_bad from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f'
       and p.proname in ('muster_engine_search_findings','muster_engine_search_evidence',
                         'insert_finding_embedding','insert_evidence_embedding',
                         'get_findings_without_embeddings','get_evidence_without_embeddings',
                         'count_findings_without_embeddings','count_evidence_without_embeddings')
       and (has_function_privilege('anon', p.oid, 'EXECUTE')
         or has_function_privilege('authenticated', p.oid, 'EXECUTE'));
    return query select 'retrieval_grants_locked', v_bad = 0,
      case when v_bad = 0 then 'all 8 retrieval functions are service_role only'
           else format('%s retrieval function(s) reachable by anon/authenticated', v_bad) end;
  exception when others then return query select 'retrieval_grants_locked', false, sqlerrm; end;

  begin
    select s.similarity into v_sim from muster.q_search_findings(v_site, v_emb, 1, 0) s limit 1;
    return query select 'findings_self_match_is_one', round(v_sim::numeric, 4) = 1.0,
      format('top self-probe similarity %s', round(coalesce(v_sim, -1)::numeric, 4));
  exception when others then return query select 'findings_self_match_is_one', false, sqlerrm; end;

  begin
    if v_ev_emb is null then
      return query select 'evidence_self_match_is_one', true, 'skipped: no evidence linked to an open finding';
    else
      select s.similarity into v_sim from muster.q_search_evidence(v_ev_site, v_ev_emb, 1, 0) s limit 1;
      return query select 'evidence_self_match_is_one', round(v_sim::numeric, 4) = 1.0,
        format('top self-probe similarity %s', round(coalesce(v_sim, -1)::numeric, 4));
    end if;
  exception when others then return query select 'evidence_self_match_is_one', false, sqlerrm; end;

  begin
    select count(*) into v_n from muster.q_search_findings(v_site, v_emb, 5, 0.6);
    select count(*) into v_distinct from muster.q_search_evidence(
      coalesce(v_ev_site, v_site), coalesce(v_ev_emb, v_emb), 5, 0.6);
    return query select 'threshold_scales_agree', (v_n > 0 and v_distinct > 0),
      format('at the shared 0.6 default: findings %s rows, evidence %s rows', v_n, v_distinct);
  exception when others then return query select 'threshold_scales_agree', false, sqlerrm; end;

  begin
    if v_ev_emb is null then
      return query select 'evidence_limit_counts_distinct', true, 'skipped: no linked evidence';
      return query select 'evidence_linkage_preserved', true, 'skipped: no linked evidence';
    else
      select count(*), count(distinct s.evidence_id) into v_n, v_distinct
        from muster.q_search_evidence(v_ev_site, v_ev_emb, 6, 0) s;
      return query select 'evidence_limit_counts_distinct', v_n = v_distinct,
        format('%s rows for %s distinct evidence ids', v_n, v_distinct);

      select count(*) into v_bad from muster.q_search_evidence(v_ev_site, v_ev_emb, 6, 0) s
       where s.finding_ids is null or cardinality(s.finding_ids) = 0;
      return query select 'evidence_linkage_preserved', v_bad = 0,
        format('%s row(s) lost their finding linkage', v_bad);
    end if;
  exception when others then return query select 'evidence_limit_counts_distinct', false, sqlerrm; end;

  begin
    perform public.muster_engine_search_findings(
      jsonb_build_object('scopes', jsonb_build_array('read'), 'organization_id', v_org + 999999),
      v_site, v_emb, 1, 0);
    return query select 'org_scope_denies_mismatch', false, 'a mismatched organization_id was NOT denied';
  exception
    when sqlstate '42501' then return query select 'org_scope_denies_mismatch', true, 'denied as expected';
    when others then return query select 'org_scope_denies_mismatch', false, sqlerrm;
  end;

  begin
    begin
      perform public.muster_engine_search_findings(
        jsonb_build_object('scopes', jsonb_build_array('read')), v_site, v_emb, 1, 0);
      v_unscoped := true;
    exception when sqlstate '42501' then
      v_unscoped := false;
    end;

    select bool_or(has_function_privilege('anon', p.oid, 'EXECUTE')
                or has_function_privilege('authenticated', p.oid, 'EXECUTE'))
      into v_reachable
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('muster_engine_search_findings','muster_engine_search_evidence');

    return query select 'platform_key_affordance_is_grant_gated',
      (not v_reachable),
      case
        when v_reachable and v_unscoped then
          'UNSAFE: a null-org context reads unscoped AND anon/authenticated can execute -- this is the cross-tenant exposure fixed in 20260908130000'
        when v_reachable then
          'UNSAFE: anon/authenticated can execute the search wrappers'
        when v_unscoped then
          'safe: null-org context reads unscoped (platform key, by design) and only service_role can execute'
        else
          'safe: null-org context is denied and only service_role can execute (stricter than agent_call)'
      end;
  exception when others then
    return query select 'platform_key_affordance_is_grant_gated', false, sqlerrm;
  end;

  begin
    select (select count(*) from muster.findings) - (select count(*) from muster.finding_embeddings)
         + (select count(*) from muster.scan_evidence) - (select count(*) from muster.evidence_embeddings)
      into v_bad;
    return query select 'embeddings_complete', v_bad = 0, format('%s record(s) unembedded', v_bad);
  exception when others then return query select 'embeddings_complete', false, sqlerrm; end;

  -- Present is not the same as current. An edited finding keeps its old vector,
  -- so embeddings_complete stays green while search answers from text that no
  -- longer exists. Measured 4 of 13 stale before the queue was wired up.
  begin
    select count(*) into v_bad
      from muster.findings f
      join muster.finding_embeddings fe on fe.finding_id = f.id
     where f.updated_at > fe.created_at;
    select v_bad + count(*) into v_bad
      from muster.embedding_queue q
     where q.processed_at is null
       and q.created_at < now() - interval '45 minutes';
    return query select 'no_stale_embeddings', v_bad = 0,
      case when v_bad = 0
           then 'no embedding older than its source, nothing queued beyond 3 drain cycles'
           else format('%s stale embedding(s) or queue rows older than 45 minutes', v_bad) end;
  exception when others then return query select 'no_stale_embeddings', false, sqlerrm; end;
end;
$function$
;

CREATE OR REPLACE FUNCTION muster.agent_tools()
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select jsonb_build_array(
    jsonb_build_object('name', 'list_websites', 'scope', 'read', 'description', 'List websites the agent can see with posture score, open findings, and latest scan.',
      'inputSchema', jsonb_build_object('type', 'object', 'properties', jsonb_build_object('organization_id', jsonb_build_object('type', 'integer', 'description', 'Required for platform-scoped keys.')))),
    jsonb_build_object('name', 'website_overview', 'scope', 'read', 'description', 'Full picture for one website: posture, open findings with evidence ids, compliance posture by law, brand, recent scans.',
      'inputSchema', jsonb_build_object('type', 'object', 'required', jsonb_build_array('website_id'), 'properties', jsonb_build_object('website_id', jsonb_build_object('type', 'integer')))),
    jsonb_build_object('name', 'list_findings', 'scope', 'read', 'description', 'Findings for a website filtered by status (open, reopened, resolved, accepted, false_positive).',
      'inputSchema', jsonb_build_object('type', 'object', 'required', jsonb_build_array('website_id'), 'properties', jsonb_build_object('website_id', jsonb_build_object('type', 'integer'), 'statuses', jsonb_build_object('type', 'array', 'items', jsonb_build_object('type', 'string'))))),
    jsonb_build_object('name', 'search_findings', 'scope', 'read', 'description', 'Semantic search over finding titles and details. Returns most relevant open findings with similarity scores. Use this to find related issues or gather context.',
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
$function$
;

CREATE OR REPLACE FUNCTION muster.engine_ingest(p_scan_id bigint, p_scan jsonb, p_evidence jsonb, p_findings jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_scan      muster.scans%rowtype;
  v_ev        jsonb;
  v_f         jsonb;
  v_ev_map    jsonb := '{}'::jsonb;
  v_ev_id     bigint;
  v_fid       bigint;
  v_inserted  boolean;
  v_prev      text;
  v_seen      bigint[] := '{}';
  v_new       integer := 0;
  v_updated   integer := 0;
  v_reopened  integer := 0;
  v_resolved  integer := 0;
  v_counts    jsonb;
  v_score     integer;
begin
  select * into v_scan from muster.scans where id = p_scan_id for update;
  if not found then
    raise exception 'scan % not found', p_scan_id;
  end if;

  for v_ev in select * from jsonb_array_elements(coalesce(p_evidence, '[]'::jsonb)) loop
    insert into muster.scan_evidence
      (scan_id, organization_id, website_id, kind, url, http_status, content_type, response_ms, headers, excerpt, byte_length, sha256)
    values
      (p_scan_id, v_scan.organization_id, v_scan.website_id, v_ev->>'kind', left(v_ev->>'url', 2048),
       nullif(v_ev->>'http_status','')::integer, left(v_ev->>'content_type', 160), nullif(v_ev->>'response_ms','')::integer,
       case when jsonb_typeof(v_ev->'headers') = 'object' then v_ev->'headers' else null end,
       left(v_ev->>'excerpt', 8192), nullif(v_ev->>'byte_length','')::integer, nullif(v_ev->>'sha256',''))
    returning id into v_ev_id;
    v_ev_map := v_ev_map || jsonb_build_object(v_ev->>'key', v_ev_id);
  end loop;

  for v_f in select * from jsonb_array_elements(coalesce(p_findings, '[]'::jsonb)) loop
    select f.status into v_prev
    from muster.findings f
    where f.website_id = v_scan.website_id
      and f.fingerprint = muster.finding_fingerprint(v_scan.website_id, v_f->>'rule_id', v_f->>'page_url', v_f->>'location');

    insert into muster.findings
      (organization_id, website_id, rule_id, fingerprint, severity, title, detail, page_url, location, confidence,
       first_seen_scan_id, last_seen_scan_id)
    values
      (v_scan.organization_id, v_scan.website_id, v_f->>'rule_id',
       muster.finding_fingerprint(v_scan.website_id, v_f->>'rule_id', v_f->>'page_url', v_f->>'location'),
       v_f->>'severity', left(v_f->>'title', 240), v_f->>'detail', left(v_f->>'page_url', 2048),
       left(v_f->>'location', 400), coalesce(v_f->>'confidence', 'high'), p_scan_id, p_scan_id)
    on conflict (website_id, fingerprint) do update set
      last_seen_scan_id = excluded.last_seen_scan_id,
      last_seen_at = now(),
      occurrences = muster.findings.occurrences + 1,
      detail = excluded.detail,
      severity = excluded.severity,
      confidence = excluded.confidence,
      status = case when muster.findings.status = 'resolved' then 'reopened' else muster.findings.status end,
      resolved_at = case when muster.findings.status = 'resolved' then null else muster.findings.resolved_at end,
      resolved_by_scan_id = case when muster.findings.status = 'resolved' then null else muster.findings.resolved_by_scan_id end
    returning id, (xmax = 0) into v_fid, v_inserted;

    if v_inserted then v_new := v_new + 1;
    elsif v_prev = 'resolved' then v_reopened := v_reopened + 1;
    else v_updated := v_updated + 1;
    end if;

    insert into muster.finding_evidence (finding_id, evidence_id, scan_id)
    select v_fid, (v_ev_map->>k)::bigint, p_scan_id
    from jsonb_array_elements_text(coalesce(v_f->'evidence_keys', '[]'::jsonb)) k
    where v_ev_map ? k
    on conflict do nothing;

    v_seen := v_seen || v_fid;
  end loop;

  -- Reconcile: open http_native findings not observed in this scan are resolved by it.
  update muster.findings f
  set status = 'resolved', resolved_at = now(), resolved_by_scan_id = p_scan_id
  where f.website_id = v_scan.website_id
    and f.status in ('open','reopened')
    and not (f.id = any (v_seen))
    and exists (select 1 from muster.scan_rules r where r.rule_id = f.rule_id and r.check_type = 'http_native');
  get diagnostics v_resolved = row_count;

  select coalesce(jsonb_object_agg(s.severity, s.n), '{}'::jsonb) into v_counts
  from (select severity, count(*) n from muster.findings
        where website_id = v_scan.website_id and status in ('open','reopened') group by severity) s;
  v_score := muster.posture_score(v_scan.website_id);

  update muster.scans set
    status = 'complete', finished_at = now(),
    final_url = left(p_scan->>'final_url', 1024),
    http_status = nullif(p_scan->>'http_status','')::integer,
    response_ms = nullif(p_scan->>'response_ms','')::integer,
    engine_version = left(p_scan->>'engine_version', 32),
    summary = jsonb_build_object(
      'open_by_severity', v_counts, 'new', v_new, 'updated', v_updated, 'reopened', v_reopened,
      'resolved', v_resolved, 'evidence', jsonb_array_length(coalesce(p_evidence, '[]'::jsonb)),
      'posture_score', v_score, 'posture_band', muster.posture_band(v_score))
  where id = p_scan_id;

  update muster.website_scan_settings set last_run_at = now() where website_id = v_scan.website_id;

  insert into muster.activity_events (organization_id, entity_type, entity_id, action, detail, actor_id)
  values (v_scan.organization_id, 'scan', p_scan_id, 'Scan completed',
    format('%s new, %s reopened, %s resolved. Posture %s (%s).', v_new, v_reopened, v_resolved, v_score, muster.posture_band(v_score)),
    v_scan.requested_by_id);

  return jsonb_build_object('scan_id', p_scan_id, 'new', v_new, 'updated', v_updated, 'reopened', v_reopened,
    'resolved', v_resolved, 'posture_score', v_score, 'posture_band', muster.posture_band(v_score));
end;
$function$
;
