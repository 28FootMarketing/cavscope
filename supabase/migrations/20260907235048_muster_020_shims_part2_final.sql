-- The remaining 15 public.muster_* shims. This completes the RPC surface at
-- 70/70, which is what makes this project reachable at all: the muster schema
-- is not exposed to PostgREST, so these are the only door.
--
-- ONE DELIBERATE DIVERGENCE, same class as do_request_scan in muster_015:
-- muster_create_api_key returns an 'mcp_url' telling the caller where to point
-- their agent. Copied verbatim it would hand every newly issued key the OLD
-- project's muster-agent endpoint. It points here instead.
set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.muster_admin_overview()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if not muster.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  return jsonb_build_object(
    'tenants', (select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'name', o.name, 'plan', o.plan, 'country_code', o.country_code,
      'region_code', o.region_code, 'onboarding_status', o.onboarding_status, 'created_at', o.created_at,
      'members', (select count(*) from muster.organization_members m where m.organization_id = o.id),
      'websites', (select count(*) from muster.websites w where w.organization_id = o.id),
      'open_critical', (select count(*) from muster.findings f where f.organization_id = o.id and f.status in ('open','reopened') and f.severity = 'critical'),
      'last_scan_at', (select max(s.finished_at) from muster.scans s where s.organization_id = o.id),
      'flag_overrides', (select count(*) from muster.feature_flag_overrides fo where fo.organization_id = o.id),
      'agents', (select count(*) from muster.agents a where a.organization_id = o.id)) order by o.created_at desc), '[]'::jsonb)
      from muster.organizations o),
    'users', (select coalesce(jsonb_agg(jsonb_build_object('id', u.id, 'name', u.name, 'email', u.email, 'role', u.role,
      'last_signed_in', u.last_signed_in) order by u.created_at desc), '[]'::jsonb) from muster.users u),
    'flags', (select coalesce(jsonb_agg(to_jsonb(f) order by f.key), '[]'::jsonb) from muster.feature_flags f),
    'overrides', (select coalesce(jsonb_agg(to_jsonb(fo) order by fo.created_at desc), '[]'::jsonb) from muster.feature_flag_overrides fo),
    'platform_agents', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'kind', a.kind, 'active', a.active,
      'keys', (select coalesce(jsonb_agg(jsonb_build_object('id', k.id, 'key_prefix', k.key_prefix, 'scopes', to_jsonb(k.scopes),
        'last_used_at', k.last_used_at, 'revoked_at', k.revoked_at)), '[]'::jsonb) from muster.api_keys k where k.agent_id = a.id))), '[]'::jsonb)
      from muster.agents a where a.organization_id is null),
    'jurisdiction_review_queue', (select coalesce(jsonb_agg(jsonb_build_object('code', j.code, 'name', j.name, 'reviewed_at', j.reviewed_at,
      'laws', (select count(*) from muster.jurisdiction_laws l where l.jurisdiction_code = j.code)) order by j.reviewed_at), '[]'::jsonb)
      from muster.jurisdictions j where j.reviewed_at < current_date - interval '180 days'),
    'engine', jsonb_build_object(
      'queued', (select count(*) from muster.scans where status = 'queued'),
      'running', (select count(*) from muster.scans where status = 'running'),
      'failed_24h', (select count(*) from muster.scans where status = 'failed' and finished_at > now() - interval '24 hours'),
      'complete_24h', (select count(*) from muster.scans where status = 'complete' and finished_at > now() - interval '24 hours'),
      'cron', (select jsonb_build_object('active', j.active, 'schedule', j.schedule) from cron.job j where j.jobname = 'muster-scan-due')),
    'alerts', jsonb_build_object(
      'pending', (select count(*) from muster.notification_outbox where status = 'pending'),
      'failed_dead_letter', (select count(*) from muster.notification_outbox where status = 'failed' and attempts >= 5),
      'sent_24h', (select count(*) from muster.notification_outbox where status = 'sent' and sent_at > now() - interval '24 hours')),
    'incidents', (select coalesce(jsonb_agg(to_jsonb(i) order by i.severity desc, i.last_seen_at desc), '[]'::jsonb)
      from muster.incidents i where i.status not in ('closed','wont_fix')),
    'pricing', public.muster_public_pricing());
end;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_admin_run_url(p_url text, p_name text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_org bigint;
  v_url text := trim(coalesce(p_url, ''));
  v_website_id bigint;
  v_result jsonb;
  v_created boolean := false;
begin
  if not muster.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  if v_url = '' then raise exception 'a url is required' using errcode = '22023'; end if;
  if v_url !~* '^https?://' then v_url := 'https://' || v_url; end if;
  if v_url !~* '^https?://[a-z0-9.-]+\.[a-z]{2,}(:[0-9]+)?(/.*)?$' then
    raise exception 'not a valid url, for example https://example.com' using errcode = '22023';
  end if;

  v_org := muster.admin_sandbox_org();
  select id into v_website_id from muster.websites where organization_id = v_org and lower(url) = lower(v_url) limit 1;

  if v_website_id is null then
    v_result := muster.do_add_website(v_org, coalesce(nullif(trim(p_name), ''), v_url), v_url, 'production', 10080, muster.current_user_id(), 'manual');
    v_created := true;
  else
    v_result := jsonb_build_object('website_id', v_website_id, 'url', v_url,
      'first_scan', muster.do_request_scan(v_website_id, muster.current_user_id(), null, 'manual'));
  end if;

  return v_result || jsonb_build_object('created', v_created);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_admin_set_flag(p_key text, p_enabled boolean, p_organization_id bigint DEFAULT NULL::bigint, p_user_id bigint DEFAULT NULL::bigint, p_reason text DEFAULT NULL::text, p_expires_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare fo muster.feature_flag_overrides;
begin
  if not muster.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_organization_id is null and p_user_id is null then
    update muster.feature_flags set default_enabled = p_enabled where key = p_key;
    return (select to_jsonb(f) from muster.feature_flags f where f.key = p_key);
  end if;
  delete from muster.feature_flag_overrides
  where flag_key = p_key and organization_id is not distinct from p_organization_id and user_id is not distinct from p_user_id;
  insert into muster.feature_flag_overrides (flag_key, organization_id, user_id, enabled, reason, set_by_id, expires_at)
  values (p_key, p_organization_id, p_user_id, p_enabled, p_reason, muster.current_user_id(), p_expires_at)
  returning * into fo;
  return to_jsonb(fo);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_create_api_key(p_organization_id bigint, p_agent_name text, p_kind text DEFAULT 'customer_agent'::text, p_scopes text[] DEFAULT ARRAY['read'::text], p_expires_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_key text; v_agent_id bigint; v_key_id bigint; v_uid bigint := muster.current_user_id();
begin
  if p_organization_id is null then
    if not muster.is_super_admin() then raise exception 'platform keys require super admin' using errcode = '42501'; end if;
  else
    if not muster.is_org_executive(p_organization_id) then raise exception 'forbidden' using errcode = '42501'; end if;
    if not muster.has_flag(p_organization_id, 'agent_api') then raise exception 'the agent API requires the Pro plan' using errcode = '42501'; end if;
  end if;
  if p_kind not in ('internal_employee','customer_agent','integration') then raise exception 'invalid agent kind' using errcode = '22023'; end if;
  if not (p_scopes <@ array['read','scan','write','admin']) then raise exception 'scopes must be from read, scan, write, admin' using errcode = '22023'; end if;
  if 'admin' = any (p_scopes) and not muster.is_super_admin() then raise exception 'admin scope requires super admin' using errcode = '42501'; end if;

  insert into muster.agents (organization_id, name, kind, created_by_id)
  values (p_organization_id, left(p_agent_name, 80), p_kind, v_uid) returning id into v_agent_id;

  v_key := 'mk_' || encode(extensions.gen_random_bytes(24), 'hex');
  insert into muster.api_keys (agent_id, organization_id, name, key_prefix, key_hash, scopes, created_by_id, expires_at)
  values (v_agent_id, p_organization_id, left(p_agent_name, 80), left(v_key, 12), encode(sha256(convert_to(v_key, 'utf8')), 'hex'), p_scopes, v_uid, p_expires_at)
  returning id into v_key_id;

  if p_organization_id is not null then
    insert into muster.activity_events (organization_id, entity_type, entity_id, action, detail, actor_id)
    values (p_organization_id, 'api_key', v_key_id, 'API key issued', p_agent_name || ' [' || array_to_string(p_scopes, ',') || ']', v_uid);
  end if;

  return jsonb_build_object('api_key', v_key, 'key_id', v_key_id, 'agent_id', v_agent_id, 'key_prefix', left(v_key, 12),
    'scopes', to_jsonb(p_scopes), 'expires_at', p_expires_at,
    'mcp_url', 'https://hjowfnzpomzxazmzywxw.supabase.co/functions/v1/muster-agent',
    'header', 'x-muster-api-key',
    'note', 'This key is shown once. Store it in your agent''s secret store.');
end;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_engine_agent_call(p_ctx jsonb, p_tool text, p_args jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_key_org bigint := nullif(p_ctx->>'organization_id', '')::bigint;
  v_agent bigint := (p_ctx->>'agent_id')::bigint;
  v_scopes text[] := array(select jsonb_array_elements_text(coalesce(p_ctx->'scopes', '[]'::jsonb)));
  v_org bigint;
  v_website bigint;
  v_need text;
  v_audience text;
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
      v_audience := coalesce(nullif(p_args->>'audience', ''), 'board');
      if v_audience not in ('board', 'plain', 'technical') then
        raise exception 'audience must be board, plain, or technical' using errcode = '22023';
      end if;
      return jsonb_build_object(
        'website_id', v_website,
        'audience', v_audience,
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
$function$
;

CREATE OR REPLACE FUNCTION public.muster_engine_search_evidence(p_ctx jsonb, p_website_id bigint, p_embedding vector, p_limit integer DEFAULT 10, p_threshold double precision DEFAULT 0.6)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'muster', 'pg_temp'
AS $function$
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
      'finding_ids', result.finding_ids,
      'chunk_text', result.chunk_text,
      'similarity', result.similarity
    ) order by result.similarity desc),
    '[]'::jsonb
  ) from muster.q_search_evidence(p_website_id, p_embedding, p_limit, p_threshold) result;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_engine_search_findings(p_ctx jsonb, p_website_id bigint, p_embedding vector, p_limit integer DEFAULT 10, p_threshold double precision DEFAULT 0.6)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'muster', 'pg_temp'
AS $function$
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
      'rule_id', result.rule_id,
      'severity', result.severity,
      'chunk_text', result.chunk_text,
      'similarity', result.similarity
    ) order by result.similarity desc),
    '[]'::jsonb
  ) from muster.q_search_findings(p_website_id, p_embedding, p_limit, p_threshold) result;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_engine_watchdog_summary()
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select jsonb_build_object(
    'silent_scans', (
      select coalesce(jsonb_agg(jsonb_build_object('scan_id', s.id, 'website_id', s.website_id, 'url', w.url)), '[]'::jsonb)
      from muster.scans s
      join muster.websites w on w.id = s.website_id
      where s.status = 'complete'
        and s.finished_at > now() - interval '20 minutes'
        and (select count(*) from muster.scan_evidence e where e.scan_id = s.id) > 0
        and (select count(*) from muster.findings f where f.last_seen_scan_id = s.id) = 0
        and exists (select 1 from muster.findings f2 where f2.website_id = w.id and f2.last_seen_scan_id <> s.id)
    ),
    'stuck_grants', (
      select coalesce(jsonb_agg(jsonb_build_object('id', g.id, 'email', g.email, 'created_at', g.created_at)), '[]'::jsonb)
      from muster.pending_commercial_grants g
      where g.applied_at is null and g.created_at < now() - interval '48 hours'
    ),
    'dead_letter_alerts', (select count(*) from muster.notification_outbox where status = 'failed' and attempts >= 5),
    'failed_scans_24h', (select count(*) from muster.scans where status = 'failed' and finished_at > now() - interval '24 hours')
  );
$function$
;

CREATE OR REPLACE FUNCTION public.muster_ghl_provision(p jsonb, p_auth_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_user muster.users;
  v_tier text := p->>'tier';
  v_stage text := p->>'stage';
  v_plan varchar;
  v_result jsonb;
  v_org_id bigint;
begin
  v_plan := case v_tier
    when 'muster' then 'starter'
    when 'muster_partner' then 'pro'
    when 'muster_enterprise' then 'enterprise'
    else null
  end;
  if v_plan is null then
    raise exception 'unknown tier: % (expected muster, muster_partner, or muster_enterprise)', v_tier using errcode = '22023';
  end if;
  if v_stage is not null and v_stage not in ('seed', 'fruit') then
    raise exception 'stage must be seed or fruit' using errcode = '22023';
  end if;
  if coalesce(p->>'admin_email', '') = '' then
    raise exception 'admin_email is required' using errcode = '22023';
  end if;

  insert into muster.users (auth_user_id, name, email, login_method, role)
  values (p_auth_user_id, coalesce(nullif(p->>'admin_name', ''), 'Admin'), lower(p->>'admin_email'), 'email', 'user')
  on conflict (auth_user_id) do update set email = excluded.email
  returning * into v_user;

  v_result := muster.do_onboard(p, v_user.id);
  v_org_id := (v_result->'organization'->>'id')::bigint;

  update muster.organizations
  set plan = v_plan,
      website_limit = (select website_limit from muster.plans where plan = v_plan),
      commercial_stage = v_stage
  where id = v_org_id;

  insert into muster.activity_events (organization_id, entity_type, entity_id, action, detail, actor_id)
  values (v_org_id, 'organization', v_org_id, 'Provisioned via GHL checkout',
    format('tier=%s stage=%s ghl_contact_id=%s', v_tier, coalesce(v_stage, 'n/a'), coalesce(p->>'ghl_contact_id', 'n/a')), v_user.id);

  return muster.q_organization(v_org_id);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_invite_member(p_organization_id bigint, p_email text, p_role text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_user_id bigint; v_auth uuid;
begin
  if not muster.is_org_executive(p_organization_id) then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_role not in ('executive','risk_owner','control_owner','contributor','viewer') then
    raise exception 'invalid role' using errcode = '22023';
  end if;
  select id into v_user_id from muster.users where lower(email) = lower(p_email);
  if v_user_id is null then
    select id into v_auth from auth.users where lower(email) = lower(p_email);
    if v_auth is null then
      return jsonb_build_object('status', 'pending_signup', 'email', lower(p_email),
        'message', 'No account with that email yet. Ask them to sign up; membership attaches on their first sign-in via muster_claim_invites.');
    end if;
    insert into muster.users (auth_user_id, name, email, login_method, role)
    values (v_auth, split_part(p_email, '@', 1), lower(p_email), 'invite', 'user')
    on conflict (auth_user_id) do update set email = excluded.email
    returning id into v_user_id;
  end if;
  insert into muster.organization_members (organization_id, user_id, role) values (p_organization_id, v_user_id, p_role)
  on conflict do nothing;
  insert into muster.activity_events (organization_id, entity_type, entity_id, action, detail, actor_id)
  values (p_organization_id, 'member', v_user_id, 'Member added', lower(p_email) || ' as ' || p_role, muster.current_user_id());
  return jsonb_build_object('status', 'added', 'user_id', v_user_id, 'role', p_role);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_onboarding_complete_step(p_step_key character varying, p_payload jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'muster', 'public'
AS $function$
declare v_user bigint; v_org bigint; v_step muster.onboarding_steps; v_site bigint; v_prev_open integer;
begin
  select user_id, org_id into v_user, v_org from muster.onboarding_caller();
  if v_org is null then raise exception 'no onboarding in progress for this user'; end if;

  select * into v_step from muster.onboarding_steps where organization_id = v_org and step_key = p_step_key;
  if v_step.id is null then raise exception 'unknown step %', p_step_key; end if;
  if v_step.completed_at is not null then return public.muster_onboarding_state(); end if;

  select count(*) into v_prev_open from muster.onboarding_steps
  where organization_id = v_org and step_no < v_step.step_no and completed_at is null;
  if v_prev_open > 0 then raise exception 'step % is locked: % earlier step(s) incomplete', p_step_key, v_prev_open; end if;

  select id into v_site from muster.websites where organization_id = v_org order by id limit 1;

  case p_step_key
    when 'account' then
      if coalesce((p_payload->>'password_set')::boolean, false) is not true then raise exception 'password must be set first'; end if;

    when 'organization' then
      if length(coalesce(p_payload->>'name','')) < 2 or length(coalesce(p_payload->>'industry','')) < 2
         or length(coalesce(p_payload->>'country_code','')) <> 2 or length(coalesce(p_payload->>'timezone','')) < 3 then
        raise exception 'organization requires name, industry, country_code (2 letters), timezone'; end if;
      update muster.organizations set name = p_payload->>'name', industry = p_payload->>'industry',
        country_code = upper(p_payload->>'country_code'), timezone = p_payload->>'timezone' where id = v_org;

    when 'website' then
      if (select verified_at from muster.websites where id = v_site) is null then
        raise exception 'website ownership not verified yet: add the meta tag then click Verify'; end if;
      update muster.website_scan_settings set enabled = true where website_id = v_site;

    when 'risk_appetite' then
      if length(coalesce(p_payload->>'statement','')) < 40 then raise exception 'risk appetite statement must be at least 40 characters'; end if;
      if coalesce((p_payload->>'critical_threshold')::int, -1) < 0 or coalesce((p_payload->>'high_threshold')::int, -1) < 0 then
        raise exception 'thresholds must be >= 0'; end if;
      if (p_payload->>'high_threshold')::int < (p_payload->>'critical_threshold')::int then
        raise exception 'high threshold must be >= critical threshold'; end if;
      if p_payload->>'review_cadence' not in ('monthly','quarterly','semi_annual','annual') then raise exception 'review_cadence invalid'; end if;
      update muster.risk_appetites set statement = p_payload->>'statement',
        critical_threshold = (p_payload->>'critical_threshold')::int, high_threshold = (p_payload->>'high_threshold')::int,
        review_cadence = p_payload->>'review_cadence', owner_id = v_user, updated_at = now(),
        next_review_at = now() + case p_payload->>'review_cadence' when 'monthly' then interval '1 month'
          when 'quarterly' then interval '3 months' when 'semi_annual' then interval '6 months' else interval '12 months' end
      where organization_id = v_org;

    when 'team' then
      if jsonb_array_length(coalesce(p_payload->'sitrep_recipients','[]'::jsonb)) < 1 then raise exception 'at least one SITREP recipient email required'; end if;
      update muster.organizations set risk_owner_id = v_user,
        sitrep_recipients = array(select jsonb_array_elements_text(p_payload->'sitrep_recipients')) where id = v_org;
      insert into muster.pending_invites (organization_id, email, role, invited_by_id)
      select v_org, e, 'contributor', v_user from jsonb_array_elements_text(coalesce(p_payload->'invites','[]'::jsonb)) e
      on conflict do nothing;

    when 'first_scan' then
      if not exists (select 1 from muster.scans where website_id = v_site and finished_at is not null) then
        if not exists (select 1 from muster.scans where website_id = v_site and finished_at is null) then
          insert into muster.scans (organization_id, website_id, trigger, status, requested_by_id, target_url, queued_at)
          select v_org, v_site, 'onboarding', 'queued', v_user, w.url, now() from muster.websites w where w.id = v_site;
          update muster.website_scan_settings set next_run_at = now() where website_id = v_site;
        end if;
        raise exception 'first scan queued; it completes automatically when the scan finishes';
      end if;

    when 'sitrep' then
      if coalesce((p_payload->>'acknowledged')::boolean, false) is not true then raise exception 'confirm you have read the SITREP'; end if;
      update muster.organizations set onboarding_status = 'complete', onboarding_completed_at = now() where id = v_org;
      insert into muster.activity_events (organization_id, entity_type, entity_id, action, detail, actor_id)
      values (v_org, 'organization', v_org, 'onboarding_complete', 'All 7 guided steps completed', v_user);
    else raise exception 'unhandled step %', p_step_key;
  end case;

  update muster.onboarding_steps set completed_at = now(), completed_by_id = v_user, payload = p_payload where id = v_step.id;
  return public.muster_onboarding_state();
end $function$
;

CREATE OR REPLACE FUNCTION public.muster_onboarding_state()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'muster', 'public'
AS $function$
declare v_user bigint; v_org bigint; v_out jsonb;
begin
  select user_id, org_id into v_user, v_org from muster.onboarding_caller();
  if v_org is null then return jsonb_build_object('error', 'no_onboarding_in_progress'); end if;
  select jsonb_build_object(
    'organization', (select to_jsonb(o) - 'created_by_id' from muster.organizations o where o.id = v_org),
    'website', (select jsonb_build_object('id', w.id, 'name', w.name, 'url', w.url, 'environment', w.environment,
                 'verification_token', w.verification_token, 'verified_at', w.verified_at)
                from muster.websites w where w.organization_id = v_org order by w.id limit 1),
    'risk_appetite', (select to_jsonb(r) from muster.risk_appetites r where r.organization_id = v_org limit 1),
    'plan', (select to_jsonb(p) from muster.plans p join muster.organizations o on o.plan = p.plan where o.id = v_org),
    'steps', (select jsonb_agg(jsonb_build_object('no', s.step_no, 'key', s.step_key, 'title', s.title,
                'completed_at', s.completed_at, 'payload', s.payload) order by s.step_no)
              from muster.onboarding_steps s where s.organization_id = v_org),
    'latest_scan', (select jsonb_build_object('id', sc.id, 'status', sc.status, 'finished_at', sc.finished_at, 'summary', sc.summary)
                    from muster.scans sc where sc.organization_id = v_org order by sc.id desc limit 1)
  ) into v_out;
  return v_out;
end $function$
;

CREATE OR REPLACE FUNCTION public.muster_save_brand(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_org bigint := (p->>'organization_id')::bigint;
  v_site bigint := nullif(p->>'website_id', '')::bigint;
  v_existing bigint;
  b muster.brand_profiles;
begin
  if not muster.is_org_executive(v_org) then raise exception 'forbidden' using errcode = '42501'; end if;
  if not muster.has_flag(v_org, 'white_label_enabled') then raise exception 'white-label branding requires the MUSTER Partner tier' using errcode = '42501'; end if;
  if coalesce(p->>'brand_name', '') = '' then raise exception 'brand_name is required' using errcode = '22023'; end if;
  if v_site is not null and muster.website_org(v_site) is distinct from v_org then raise exception 'website does not belong to this organization' using errcode = '42501'; end if;
  if coalesce(p->>'custom_domain', '') <> '' and not muster.has_flag(v_org, 'custom_domain_enabled') then
    raise exception 'custom domains require the MUSTER Partner tier' using errcode = '42501';
  end if;
  if coalesce((p->>'hide_muster_attribution')::boolean, false) and not muster.has_flag(v_org, 'hide_attribution') then
    raise exception 'attribution removal requires the MUSTER Partner tier' using errcode = '42501';
  end if;
  if coalesce(p->>'client_payment_url', '') <> '' and p->>'client_payment_url' !~* '^https?://' then
    raise exception 'client payment link must start with http:// or https://' using errcode = '22023';
  end if;

  select id into v_existing from muster.brand_profiles
  where organization_id = v_org and website_id is not distinct from v_site;

  if v_existing is null then
    insert into muster.brand_profiles (organization_id, website_id, brand_name, brand_mark, eyebrow, primary_color, accent_color,
      logo_url, favicon_url, custom_domain, support_email, support_url, report_disclaimer, report_signoff_name, report_signoff_title,
      welcome_message, tone, locale, hide_muster_attribution, client_price_amount, client_price_cadence, client_payment_url,
      client_pricing_note, created_by_id)
    values (v_org, v_site, left(p->>'brand_name', 80), upper(left(coalesce(nullif(p->>'brand_mark', ''), left(p->>'brand_name', 2)), 4)),
      left(coalesce(nullif(p->>'eyebrow', ''), 'Website Assurance'), 80),
      coalesce(nullif(p->>'primary_color', ''), '#36e2c9'), coalesce(nullif(p->>'accent_color', ''), '#f5b942'),
      nullif(p->>'logo_url', ''), nullif(p->>'favicon_url', ''), lower(nullif(p->>'custom_domain', '')), nullif(p->>'support_email', ''),
      nullif(p->>'support_url', ''),
      coalesce(nullif(p->>'report_disclaimer', ''), 'Prepared under the MUSTER Assurance Framework by 28 Foot Systems. All rights reserved.'),
      nullif(p->>'report_signoff_name', ''), nullif(p->>'report_signoff_title', ''), nullif(p->>'welcome_message', ''),
      coalesce(nullif(p->>'tone', ''), 'executive'), coalesce(nullif(p->>'locale', ''), 'en-US'),
      coalesce((p->>'hide_muster_attribution')::boolean, false),
      nullif(p->>'client_price_amount', '')::numeric, nullif(p->>'client_price_cadence', ''),
      nullif(p->>'client_payment_url', ''), nullif(p->>'client_pricing_note', ''), muster.current_user_id())
    returning * into b;
  else
    update muster.brand_profiles set
      brand_name = left(p->>'brand_name', 80),
      brand_mark = upper(left(coalesce(nullif(p->>'brand_mark', ''), left(p->>'brand_name', 2)), 4)),
      eyebrow = left(coalesce(nullif(p->>'eyebrow', ''), 'Website Assurance'), 80),
      primary_color = coalesce(nullif(p->>'primary_color', ''), '#36e2c9'),
      accent_color = coalesce(nullif(p->>'accent_color', ''), '#f5b942'),
      logo_url = nullif(p->>'logo_url', ''), favicon_url = nullif(p->>'favicon_url', ''),
      custom_domain = lower(nullif(p->>'custom_domain', '')),
      support_email = nullif(p->>'support_email', ''), support_url = nullif(p->>'support_url', ''),
      report_disclaimer = coalesce(nullif(p->>'report_disclaimer', ''), report_disclaimer),
      report_signoff_name = nullif(p->>'report_signoff_name', ''), report_signoff_title = nullif(p->>'report_signoff_title', ''),
      welcome_message = nullif(p->>'welcome_message', ''),
      tone = coalesce(nullif(p->>'tone', ''), 'executive'), locale = coalesce(nullif(p->>'locale', ''), 'en-US'),
      hide_muster_attribution = coalesce((p->>'hide_muster_attribution')::boolean, false),
      client_price_amount = nullif(p->>'client_price_amount', '')::numeric,
      client_price_cadence = nullif(p->>'client_price_cadence', ''),
      client_payment_url = nullif(p->>'client_payment_url', ''),
      client_pricing_note = nullif(p->>'client_pricing_note', '')
    where id = v_existing returning * into b;
  end if;

  insert into muster.activity_events (organization_id, entity_type, entity_id, action, detail, actor_id)
  values (v_org, 'brand_profile', b.id, 'Brand profile saved', b.brand_name, muster.current_user_id());
  return muster.q_brand(v_org, v_site);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_save_preferences(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare u muster.users; pf muster.user_preferences;
begin
  u := muster.ensure_user_from_auth();
  if p ? 'default_organization_id' and nullif(p->>'default_organization_id', '') is not null
     and not muster.is_org_member((p->>'default_organization_id')::bigint) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  update muster.user_preferences set
    theme = coalesce(nullif(p->>'theme', ''), theme),
    density = coalesce(nullif(p->>'density', ''), density),
    default_organization_id = coalesce(nullif(p->>'default_organization_id', '')::bigint, default_organization_id),
    default_view = coalesce(nullif(p->>'default_view', ''), default_view),
    digest_cadence = coalesce(nullif(p->>'digest_cadence', ''), digest_cadence),
    notify_channel = coalesce(nullif(p->>'notify_channel', ''), notify_channel),
    telegram_chat_id = coalesce(nullif(p->>'telegram_chat_id', ''), telegram_chat_id),
    preferred_name = coalesce(nullif(p->>'preferred_name', ''), preferred_name)
  where user_id = u.id returning * into pf;
  if p ? 'name' and coalesce(p->>'name', '') <> '' then
    update muster.users set name = left(p->>'name', 120) where id = u.id;
  end if;
  return to_jsonb(pf);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_save_risk_appetite(p_organization_id bigint, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_uid bigint := muster.current_user_id();
begin
  if not muster.can_write_org(p_organization_id) then raise exception 'forbidden' using errcode = '42501'; end if;
  update muster.risk_appetites set
    statement = coalesce(nullif(p->>'statement', ''), statement),
    critical_threshold = coalesce((p->>'critical_threshold')::int, critical_threshold),
    high_threshold = coalesce((p->>'high_threshold')::int, high_threshold),
    review_cadence = coalesce(nullif(p->>'review_cadence', ''), review_cadence),
    next_review_at = coalesce((p->>'next_review_at')::timestamptz, next_review_at),
    updated_at = now()
  where organization_id = p_organization_id;
  if not found then
    insert into muster.risk_appetites (organization_id, statement, critical_threshold, high_threshold, review_cadence, next_review_at, owner_id)
    values (p_organization_id, coalesce(p->>'statement', 'Risk appetite not yet defined.'),
      coalesce((p->>'critical_threshold')::int, 0), coalesce((p->>'high_threshold')::int, 2),
      coalesce(nullif(p->>'review_cadence', ''), 'quarterly'),
      coalesce((p->>'next_review_at')::timestamptz, now() + interval '90 days'), v_uid);
  end if;
  return (select to_jsonb(ra) from muster.risk_appetites ra where ra.organization_id = p_organization_id);
end;
$function$
;
