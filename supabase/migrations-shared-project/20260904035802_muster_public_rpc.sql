-- MUSTER phase 1: public.muster_* RPC surface.
-- Project: mgtmqucaldkaxvxglguw
-- PostgREST may not expose the muster schema, so every client call goes through public.muster_* functions
-- (house pattern: public.rios_* shims). Internal query/action logic lives in muster.q_* and muster.do_*
-- (SECURITY DEFINER, service_role only) and is shared by the user RPCs, the engine, and the agent gateway.

------------------------------------------------------------------------------
-- Internal: user provisioning
------------------------------------------------------------------------------
create or replace function muster.ensure_user_from_auth()
returns muster.users
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_email text;
  v_name text;
  v_provider text;
  u muster.users;
begin
  if v_uid is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;
  select au.email, coalesce(au.raw_user_meta_data->>'full_name', au.raw_user_meta_data->>'name', split_part(au.email, '@', 1)),
         coalesce(au.raw_app_meta_data->>'provider', 'email')
  into v_email, v_name, v_provider
  from auth.users au where au.id = v_uid;

  insert into muster.users (auth_user_id, name, email, login_method, role, last_signed_in)
  values (v_uid, left(v_name, 120), left(v_email, 320), left(v_provider, 64), 'user', now())
  on conflict (auth_user_id) do update set
    email = excluded.email, login_method = excluded.login_method, last_signed_in = now(),
    name = coalesce(nullif(muster.users.name, ''), excluded.name)
  returning * into u;

  insert into muster.user_preferences (user_id) values (u.id) on conflict (user_id) do nothing;
  return u;
end;
$$;

------------------------------------------------------------------------------
-- Internal: queries
------------------------------------------------------------------------------
create or replace function muster.q_flags(p_org bigint)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_object_agg(f.key, muster.has_flag(p_org, f.key)), '{}'::jsonb) from muster.feature_flags f;
$$;

create or replace function muster.q_brand(p_org bigint, p_website_id bigint default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  b muster.brand_profiles%rowtype;
  v_wl boolean := muster.has_flag(p_org, 'white_label');
  v_hide boolean := muster.has_flag(p_org, 'hide_attribution');
  v_domain boolean := muster.has_flag(p_org, 'custom_domain');
begin
  if p_website_id is not null then
    select * into b from muster.brand_profiles where website_id = p_website_id;
  end if;
  if b.id is null then
    select * into b from muster.brand_profiles where organization_id = p_org and website_id is null;
  end if;
  if b.id is null or not v_wl then
    return jsonb_build_object('is_custom', false, 'locked', not v_wl, 'mode', 'muster',
      'brand_name', 'MUSTER', 'brand_mark', 'MU', 'eyebrow', '28 Foot Systems',
      'primary_color', '#36e2c9', 'accent_color', '#f5b942', 'logo_url', null, 'favicon_url', null,
      'report_disclaimer', 'Prepared under the MUSTER Assurance Framework by 28 Foot Systems. All rights reserved.',
      'hide_muster_attribution', false, 'tone', 'executive', 'locale', 'en-US', 'custom_domain', null,
      'saved_profile', case when b.id is null then null else to_jsonb(b) end);
  end if;
  return to_jsonb(b) || jsonb_build_object('is_custom', true, 'locked', false, 'mode', 'white_label',
    'hide_muster_attribution', (b.hide_muster_attribution and v_hide),
    'custom_domain', case when v_domain then b.custom_domain else null end);
end;
$$;

create or replace function muster.q_jurisdiction_advisory(p_country text, p_region text, p_full boolean)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_country text := upper(coalesce(p_country, ''));
  v_region text := case when coalesce(p_region, '') = '' then null else upper(p_country) || '-' || upper(p_region) end;
  v_parent text;
  v_codes text[];
  v_j jsonb;
  v_laws jsonb;
  v_profile boolean;
begin
  select parent_code into v_parent from muster.jurisdictions where code = v_country;
  v_profile := found;
  v_codes := array_remove(array['GLOBAL', v_parent, v_country, v_region], null);

  select coalesce(jsonb_agg(jsonb_build_object('code', j.code, 'kind', j.kind, 'name', j.name, 'advisory', j.advisory,
           'reviewed_at', j.reviewed_at) order by array_position(v_codes, j.code)), '[]'::jsonb)
  into v_j from muster.jurisdictions j where j.code = any (v_codes);

  if p_full then
    select coalesce(jsonb_agg(jsonb_build_object('law_id', l.id, 'jurisdiction_code', l.jurisdiction_code, 'short_name', l.short_name,
             'full_name', l.full_name, 'category', l.category, 'applies_when', l.applies_when, 'summary', l.summary,
             'obligations', l.obligations, 'rule_ids', to_jsonb(l.rule_ids), 'effective_date', l.effective_date,
             'reference_url', l.reference_url, 'reviewed_at', l.reviewed_at)
             order by array_position(v_codes, l.jurisdiction_code), l.category, l.short_name), '[]'::jsonb)
    into v_laws from muster.jurisdiction_laws l where l.jurisdiction_code = any (v_codes);
  else
    select coalesce(jsonb_agg(jsonb_build_object('jurisdiction_code', l.jurisdiction_code, 'short_name', l.short_name,
             'full_name', l.full_name, 'category', l.category)
             order by array_position(v_codes, l.jurisdiction_code), l.category, l.short_name), '[]'::jsonb)
    into v_laws from muster.jurisdiction_laws l where l.jurisdiction_code = any (v_codes);
  end if;

  return jsonb_build_object('country_code', nullif(v_country, ''), 'region_code', v_region,
    'profile_available', v_profile, 'depth', case when p_full then 'full' else 'summary' end,
    'jurisdictions', v_j, 'laws', v_laws, 'law_count', jsonb_array_length(v_laws),
    'note', case when v_profile then null else 'No jurisdiction profile for this country yet. The global baseline applies; a super admin can add a profile.' end,
    'disclaimer', 'Informational only. MUSTER is not a law firm and this is not legal advice. Confirm applicability with counsel.');
end;
$$;

create or replace function muster.q_compliance_posture(p_website_id bigint)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_country text; v_region text; v_parent text; v_codes text[];
  v_scanned boolean;
begin
  select o.country_code, o.region_code into v_country, v_region
  from muster.websites w join muster.organizations o on o.id = w.organization_id where w.id = p_website_id;
  select parent_code into v_parent from muster.jurisdictions where code = v_country;
  v_codes := array_remove(array['GLOBAL', v_parent, v_country,
    case when v_region is null then null else v_country || '-' || v_region end], null);
  v_scanned := exists (select 1 from muster.scans where website_id = p_website_id and status = 'complete');

  return jsonb_build_object(
    'website_id', p_website_id, 'country_code', v_country, 'region_code', v_region, 'scanned', v_scanned,
    'laws', (
      select coalesce(jsonb_agg(x order by x->>'jurisdiction_rank', x->>'category', x->>'short_name'), '[]'::jsonb)
      from (
        select jsonb_build_object(
          'law_id', l.id, 'jurisdiction_code', l.jurisdiction_code, 'jurisdiction_rank', array_position(v_codes, l.jurisdiction_code),
          'short_name', l.short_name, 'full_name', l.full_name, 'category', l.category, 'applies_when', l.applies_when,
          'obligations', l.obligations, 'rule_ids', to_jsonb(l.rule_ids), 'reference_url', l.reference_url,
          'open_findings', f.n, 'finding_ids', f.ids,
          'status', case when cardinality(l.rule_ids) = 0 then 'manual_review'
                         when not v_scanned then 'not_scanned'
                         when f.n > 0 then 'evidence_gap' else 'clear' end) as x
        from muster.jurisdiction_laws l
        cross join lateral (
          select count(*) as n, coalesce(jsonb_agg(fi.id), '[]'::jsonb) as ids
          from muster.findings fi
          where fi.website_id = p_website_id and fi.status in ('open','reopened') and fi.rule_id = any (l.rule_ids)) f
        where l.jurisdiction_code = any (v_codes)) s),
    'disclaimer', 'Statuses reflect scanner evidence only. "clear" means no open scanner finding maps to the law; it is not a certification of compliance.');
end;
$$;

create or replace function muster.q_findings(p_website_id bigint, p_statuses text[] default array['open','reopened'])
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', f.id, 'website_id', f.website_id, 'rule_id', f.rule_id, 'category', r.category, 'severity', f.severity,
    'status', f.status, 'title', f.title, 'detail', f.detail, 'page_url', f.page_url, 'location', f.location,
    'confidence', f.confidence, 'occurrences', f.occurrences, 'first_seen_at', f.first_seen_at, 'last_seen_at', f.last_seen_at,
    'resolved_at', f.resolved_at, 'status_note', f.status_note, 'risk_id', f.risk_id,
    'remediation', r.remediation, 'plain_english', r.plain_english, 'framework_refs', r.framework_refs,
    'evidence_ids', (select coalesce(jsonb_agg(fe.evidence_id order by fe.evidence_id), '[]'::jsonb) from muster.finding_evidence fe where fe.finding_id = f.id))
    order by muster.severity_rank(f.severity), f.last_seen_at desc, f.id), '[]'::jsonb)
  from muster.findings f join muster.scan_rules r on r.rule_id = f.rule_id
  where f.website_id = p_website_id and f.status = any (p_statuses);
$$;

create or replace function muster.q_scans(p_website_id bigint, p_limit integer default 20)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(to_jsonb(s) order by s.created_at desc), '[]'::jsonb)
  from (select * from muster.scans where website_id = p_website_id order by created_at desc limit greatest(1, least(p_limit, 100))) s;
$$;

create or replace function muster.q_sitrep(p_sitrep_id bigint)
returns jsonb language sql stable security definer set search_path = '' as $$
  select to_jsonb(s) from muster.sitreps s where s.id = p_sitrep_id;
$$;

create or replace function muster.q_latest_sitrep(p_website_id bigint)
returns jsonb language sql stable security definer set search_path = '' as $$
  select to_jsonb(s) from muster.sitreps s where s.website_id = p_website_id order by s.generated_at desc limit 1;
$$;

create or replace function muster.q_evidence(p_evidence_id bigint)
returns jsonb language sql stable security definer set search_path = '' as $$
  select to_jsonb(e) || jsonb_build_object('finding_ids',
    (select coalesce(jsonb_agg(fe.finding_id), '[]'::jsonb) from muster.finding_evidence fe where fe.evidence_id = e.id))
  from muster.scan_evidence e where e.id = p_evidence_id;
$$;

create or replace function muster.q_website_summary(p_website_id bigint)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', w.id, 'organization_id', w.organization_id, 'name', w.name, 'url', w.url, 'environment', w.environment,
    'created_at', w.created_at,
    'posture_score', muster.posture_score(w.id), 'posture_band', muster.posture_band(muster.posture_score(w.id)),
    'open_findings', (select count(*) from muster.findings f where f.website_id = w.id and f.status in ('open','reopened')),
    'open_by_severity', (select coalesce(jsonb_object_agg(x.severity, x.n), '{}'::jsonb) from
       (select severity, count(*) n from muster.findings where website_id = w.id and status in ('open','reopened') group by 1) x),
    'scan_settings', (select to_jsonb(st) from muster.website_scan_settings st where st.website_id = w.id),
    'latest_scan', (select to_jsonb(s) from muster.scans s where s.website_id = w.id order by s.created_at desc limit 1),
    'latest_sitrep', (select jsonb_build_object('id', sr.id, 'headline', sr.headline, 'posture_score', sr.posture_score,
       'posture_band', sr.posture_band, 'generated_at', sr.generated_at, 'scan_id', sr.scan_id)
       from muster.sitreps sr where sr.website_id = w.id order by sr.generated_at desc limit 1))
  from muster.websites w where w.id = p_website_id;
$$;

create or replace function muster.q_website_overview(p_website_id bigint)
returns jsonb language sql stable security definer set search_path = '' as $$
  select muster.q_website_summary(p_website_id)
    || jsonb_build_object(
         'compliance', muster.q_compliance_posture(p_website_id),
         'brand', muster.q_brand(muster.website_org(p_website_id), p_website_id),
         'findings', muster.q_findings(p_website_id, array['open','reopened']),
         'recent_scans', muster.q_scans(p_website_id, 10));
$$;

create or replace function muster.q_organization(p_org bigint)
returns jsonb language sql stable security definer set search_path = '' as $$
  select to_jsonb(o) || jsonb_build_object(
    'plan_detail', (select to_jsonb(p) from muster.plans p where p.plan = o.plan),
    'flags', muster.q_flags(o.id),
    'brand', muster.q_brand(o.id, null),
    'advisory', muster.q_jurisdiction_advisory(o.country_code, o.region_code, false),
    'members', (select coalesce(jsonb_agg(jsonb_build_object('user_id', m.user_id, 'name', u.name, 'email', u.email, 'role', m.role)), '[]'::jsonb)
                from muster.organization_members m join muster.users u on u.id = m.user_id where m.organization_id = o.id),
    'websites', (select coalesce(jsonb_agg(muster.q_website_summary(w.id) order by w.created_at), '[]'::jsonb)
                 from muster.websites w where w.organization_id = o.id),
    'agents', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'kind', a.kind, 'active', a.active,
                 'keys', (select coalesce(jsonb_agg(jsonb_build_object('id', k.id, 'name', k.name, 'key_prefix', k.key_prefix,
                            'scopes', to_jsonb(k.scopes), 'last_used_at', k.last_used_at, 'expires_at', k.expires_at, 'revoked_at', k.revoked_at)), '[]'::jsonb)
                          from muster.api_keys k where k.agent_id = a.id))), '[]'::jsonb)
               from muster.agents a where a.organization_id = o.id))
  from muster.organizations o where o.id = p_org;
$$;

------------------------------------------------------------------------------
-- Internal: actions
------------------------------------------------------------------------------
create or replace function muster.do_request_scan(p_website_id bigint, p_user_id bigint, p_agent_id bigint, p_trigger text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_org bigint;
  v_url text;
  v_existing bigint;
  v_scan_id bigint;
  v_anon text;
  v_secret text;
begin
  select organization_id, url into v_org, v_url from muster.websites where id = p_website_id;
  if v_org is null then raise exception 'website % not found', p_website_id using errcode = 'P0002'; end if;

  select id into v_existing from muster.scans
  where website_id = p_website_id and status in ('queued','running') order by created_at desc limit 1;
  if v_existing is not null then
    return jsonb_build_object('scan_id', v_existing, 'status', 'in_flight', 'deduplicated', true);
  end if;

  insert into muster.scans (organization_id, website_id, trigger, status, requested_by_id, requested_by_agent_id, target_url)
  values (v_org, p_website_id, p_trigger, 'queued', p_user_id, p_agent_id, v_url)
  returning id into v_scan_id;

  insert into muster.activity_events (organization_id, entity_type, entity_id, action, detail, actor_id, agent_id)
  values (v_org, 'scan', v_scan_id, 'Scan requested', 'Trigger: ' || p_trigger, p_user_id, p_agent_id);

  -- Kick the engine now. If pg_net fails, the cron sweep claims queued scans after 2 minutes.
  begin
    select decrypted_secret into v_anon from vault.decrypted_secrets where name = 'supabase_anon_key' limit 1;
    select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'muster_cron_secret' limit 1;
    perform net.http_post(
      url := 'https://mgtmqucaldkaxvxglguw.supabase.co/functions/v1/muster-scan',
      headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_anon, 'x-muster-secret', v_secret),
      body := jsonb_build_object('scan_id', v_scan_id),
      timeout_milliseconds := 120000);
  exception when others then
    insert into muster.activity_events (organization_id, entity_type, entity_id, action, detail)
    values (v_org, 'scan', v_scan_id, 'Engine kick deferred', left(SQLERRM, 500));
  end;

  return jsonb_build_object('scan_id', v_scan_id, 'status', 'queued', 'deduplicated', false);
end;
$$;

create or replace function muster.do_update_finding_status(p_finding_id bigint, p_status text, p_note text, p_user_id bigint, p_agent_id bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare f muster.findings%rowtype;
begin
  if p_status not in ('open','accepted','false_positive','resolved') then
    raise exception 'status must be open, accepted, false_positive, or resolved' using errcode = '22023';
  end if;
  update muster.findings set
    status = p_status,
    status_note = left(p_note, 2000),
    status_changed_by_id = p_user_id,
    resolved_at = case when p_status = 'resolved' then now() when p_status = 'open' then null else resolved_at end
  where id = p_finding_id
  returning * into f;
  if f.id is null then raise exception 'finding % not found', p_finding_id using errcode = 'P0002'; end if;
  insert into muster.activity_events (organization_id, entity_type, entity_id, action, detail, actor_id, agent_id)
  values (f.organization_id, 'finding', f.id, 'Finding status set to ' || p_status, left(coalesce(p_note, ''), 500), p_user_id, p_agent_id);
  return to_jsonb(f);
end;
$$;

create or replace function muster.do_promote_finding(p_finding_id bigint, p_user_id bigint, p_agent_id bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  f muster.findings%rowtype;
  r muster.scan_rules%rowtype;
  v_risk_id bigint;
  v_evidence_id bigint;
  v_ev_ids text;
  v_score integer;
begin
  select * into f from muster.findings where id = p_finding_id;
  if f.id is null then raise exception 'finding % not found', p_finding_id using errcode = 'P0002'; end if;
  if f.risk_id is not null then
    return jsonb_build_object('risk_id', f.risk_id, 'already_promoted', true);
  end if;
  select * into r from muster.scan_rules where rule_id = f.rule_id;
  v_score := case f.severity when 'critical' then 20 when 'high' then 15 when 'medium' then 9 when 'low' then 4 else 2 end;
  select string_agg('E' || fe.evidence_id, ', ' order by fe.evidence_id) into v_ev_ids
  from muster.finding_evidence fe where fe.finding_id = f.id;

  insert into muster.risks (website_id, title, description, category, source, severity, status, inherent_score, residual_score,
    treatment, treatment_plan, owner_id, identified_at, escalation_context)
  values (f.website_id, left(f.title, 240),
    f.detail || E'\n\nPage: ' || f.page_url || coalesce(E'\nLocation: ' || f.location, '') || E'\nScanner rule ' || f.rule_id || ' (' || f.confidence || ' confidence). Evidence: ' || coalesce(v_ev_ids, 'none'),
    r.category,
    case r.category when 'security' then 'security_scan' when 'accessibility' then 'accessibility_audit'
      when 'privacy' then 'privacy_assessment' when 'third_party' then 'vendor_assessment' else 'other' end,
    case f.severity when 'info' then 'low' else f.severity end,
    'open', v_score, v_score, 'mitigate', r.remediation, p_user_id, f.first_seen_at,
    'Promoted from MUSTER finding F' || f.id)
  returning id into v_risk_id;

  insert into muster.evidence (website_id, title, description, evidence_type, review_state, source_url, owner_id, audit_context)
  values (f.website_id, left('Scan evidence for ' || f.title, 240),
    'Captured by the MUSTER scan engine. Scan evidence rows: ' || coalesce(v_ev_ids, 'none') || '. Finding F' || f.id || '.',
    'scan', 'pending', left(f.page_url, 1024), p_user_id, 'Rule ' || f.rule_id || ' ' || r.framework_refs::text)
  returning id into v_evidence_id;

  insert into muster.evidence_links (evidence_id, risk_id) values (v_evidence_id, v_risk_id);
  update muster.findings set risk_id = v_risk_id where id = f.id;
  insert into muster.activity_events (organization_id, entity_type, entity_id, action, detail, actor_id, agent_id)
  values (f.organization_id, 'risk', v_risk_id, 'Risk created from finding', 'Finding F' || f.id || ' promoted to the risk register', p_user_id, p_agent_id);

  return jsonb_build_object('risk_id', v_risk_id, 'evidence_id', v_evidence_id, 'already_promoted', false);
end;
$$;

create or replace function muster.do_add_website(p_org bigint, p_name text, p_url text, p_environment text, p_cadence_minutes integer,
                                                 p_user_id bigint, p_trigger text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_count integer;
  v_limit integer;
  v_min_cadence integer;
  v_url text := trim(p_url);
  v_website_id bigint;
  v_scan jsonb;
begin
  if v_url !~* '^https?://[a-z0-9.-]+\.[a-z]{2,}(:[0-9]+)?(/.*)?$' then
    raise exception 'website url must be a full http(s) address, for example https://example.com' using errcode = '22023';
  end if;
  select count(*) into v_count from muster.websites where organization_id = p_org;
  select p.website_limit, p.scan_cadence_min_minutes into v_limit, v_min_cadence
  from muster.organizations o join muster.plans p on p.plan = o.plan where o.id = p_org;
  if v_count >= 1 and not muster.has_flag(p_org, 'multi_website') then
    raise exception 'this plan allows one website. Upgrade to add more.' using errcode = '42501';
  end if;
  if v_count >= v_limit then
    raise exception 'website limit (%) reached for this plan', v_limit using errcode = '42501';
  end if;

  insert into muster.websites (name, url, environment, owner_id, organization_id)
  values (left(coalesce(nullif(trim(p_name), ''), regexp_replace(v_url, '^https?://([^/]+).*$', '\1')), 160), left(v_url, 512),
          coalesce(p_environment, 'production'), p_user_id, p_org)
  returning id into v_website_id;

  insert into muster.website_scan_settings (website_id, cadence_minutes, next_run_at)
  values (v_website_id, greatest(coalesce(p_cadence_minutes, 1440), v_min_cadence), now() + interval '1 day');

  insert into muster.activity_events (organization_id, entity_type, entity_id, action, detail, actor_id)
  values (p_org, 'website', v_website_id, 'Website added', v_url, p_user_id);

  v_scan := muster.do_request_scan(v_website_id, p_user_id, null, p_trigger);
  return jsonb_build_object('website_id', v_website_id, 'url', v_url, 'first_scan', v_scan);
end;
$$;

create or replace function muster.do_onboard(p jsonb, p_user_id bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_org_id bigint;
  v_name text := left(trim(coalesce(p->>'org_name', '')), 160);
  v_country text := upper(left(coalesce(p->>'country_code', ''), 2));
  v_region text := nullif(upper(left(coalesce(p->>'region_code', ''), 8)), '');
  v_tz text := coalesce(nullif(p->>'timezone', ''), 'America/New_York');
  v_owned integer;
  v_site jsonb;
  v_brand jsonb := p->'brand';
begin
  if v_name = '' then raise exception 'org_name is required' using errcode = '22023'; end if;
  if not exists (select 1 from muster.countries where code = v_country) then
    raise exception 'country_code must be an ISO 3166-1 alpha-2 code' using errcode = '22023';
  end if;
  if v_region is not null and not exists (select 1 from muster.jurisdictions where code = v_country || '-' || v_region) then
    raise exception 'region_code % is not known for country %', v_region, v_country using errcode = '22023';
  end if;
  select count(*) into v_owned from muster.organizations where created_by_id = p_user_id;
  if v_owned >= 5 and not muster.is_super_admin() then
    raise exception 'organization limit reached for this account' using errcode = '42501';
  end if;

  insert into muster.organizations (name, industry, risk_owner_id, plan, country_code, region_code, timezone, website_limit,
    onboarding_status, created_by_id)
  values (v_name, left(nullif(p->>'industry', ''), 120), p_user_id, 'trial', v_country, v_region, v_tz,
    (select website_limit from muster.plans where plan = 'trial'), 'profile', p_user_id)
  returning id into v_org_id;

  insert into muster.organization_members (organization_id, user_id, role) values (v_org_id, p_user_id, 'executive');

  insert into muster.risk_appetites (organization_id, statement, critical_threshold, high_threshold, review_cadence, next_review_at, owner_id)
  values (v_org_id, 'No open critical website findings. High findings remediated within 30 days.', 0, 2, 'quarterly', now() + interval '90 days', p_user_id);

  if v_brand is not null and coalesce(v_brand->>'brand_name', '') <> '' then
    insert into muster.brand_profiles (organization_id, brand_name, brand_mark, eyebrow, primary_color, accent_color, logo_url,
      support_email, report_signoff_name, report_signoff_title, welcome_message, tone, created_by_id)
    values (v_org_id, left(v_brand->>'brand_name', 80),
      upper(left(coalesce(nullif(v_brand->>'brand_mark', ''), left(v_brand->>'brand_name', 2)), 4)),
      left(coalesce(nullif(v_brand->>'eyebrow', ''), 'Website Assurance'), 80),
      coalesce(nullif(v_brand->>'primary_color', ''), '#36e2c9'), coalesce(nullif(v_brand->>'accent_color', ''), '#f5b942'),
      nullif(v_brand->>'logo_url', ''), nullif(v_brand->>'support_email', ''), nullif(v_brand->>'report_signoff_name', ''),
      nullif(v_brand->>'report_signoff_title', ''), nullif(v_brand->>'welcome_message', ''),
      coalesce(nullif(v_brand->>'tone', ''), 'executive'), p_user_id);
  end if;

  update muster.user_preferences set default_organization_id = v_org_id,
    preferred_name = coalesce(nullif(p->>'preferred_name', ''), preferred_name)
  where user_id = p_user_id;

  insert into muster.activity_events (organization_id, entity_type, entity_id, action, detail, actor_id)
  values (v_org_id, 'organization', v_org_id, 'Organization created (self-serve onboarding)',
    'Jurisdiction ' || v_country || coalesce('-' || v_region, ''), p_user_id);

  if coalesce(p->>'website_url', '') <> '' then
    update muster.organizations set onboarding_status = 'website' where id = v_org_id;
    v_site := muster.do_add_website(v_org_id, p->>'website_name', p->>'website_url', coalesce(p->>'environment', 'production'), 1440, p_user_id, 'onboarding');
    update muster.organizations set onboarding_status = 'complete', onboarding_completed_at = now() where id = v_org_id;
  end if;

  return jsonb_build_object(
    'organization', muster.q_organization(v_org_id),
    'website', v_site,
    'advisory', muster.q_jurisdiction_advisory(v_country, v_region, true),
    'next_steps', jsonb_build_array(
      case when v_site is null then 'Add your first website to start the scan.' else 'Your first scan is running. The SITREP will appear in a few minutes.' end,
      'Invite a risk owner and a control owner from Settings.',
      'Review the jurisdiction obligations mapped to your scan evidence.',
      'Set your brand profile if you deliver reports under your own name.'));
end;
$$;

------------------------------------------------------------------------------
-- Public RPC: anonymous-capable (onboarding dropdowns and advisory)
------------------------------------------------------------------------------
create or replace function public.muster_countries()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('code', c.code, 'name', c.name, 'has_regions', c.has_regions,
           'has_profile', exists (select 1 from muster.jurisdictions j where j.code = c.code)) order by c.name), '[]'::jsonb)
  from muster.countries c;
$$;

create or replace function public.muster_regions(p_country_code text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('code', split_part(j.code, '-', 2), 'name', j.name) order by j.name), '[]'::jsonb)
  from muster.jurisdictions j where j.kind = 'region' and j.country_code = upper(p_country_code);
$$;

create or replace function public.muster_jurisdiction_advisory(p_country_code text, p_region_code text default null, p_depth text default 'summary')
returns jsonb language sql stable security definer set search_path = '' as $$
  select muster.q_jurisdiction_advisory(p_country_code, p_region_code, p_depth = 'full' and (select auth.uid()) is not null);
$$;

create or replace function public.muster_plans()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(to_jsonb(p) order by p.rank), '[]'::jsonb) from muster.plans p where p.plan <> 'internal';
$$;

------------------------------------------------------------------------------
-- Public RPC: signed-in users
------------------------------------------------------------------------------
create or replace function public.muster_ensure_user()
returns jsonb language sql security definer set search_path = '' as $$
  select to_jsonb(muster.ensure_user_from_auth());
$$;

create or replace function public.muster_onboarding_status()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare u muster.users; v_orgs jsonb;
begin
  u := muster.ensure_user_from_auth();
  select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'name', o.name, 'onboarding_status', o.onboarding_status, 'role', m.role,
           'websites', (select count(*) from muster.websites w where w.organization_id = o.id))), '[]'::jsonb)
  into v_orgs
  from muster.organization_members m join muster.organizations o on o.id = m.organization_id where m.user_id = u.id;
  return jsonb_build_object('user', to_jsonb(u), 'organizations', v_orgs,
    'self_serve_enabled', muster.has_flag(null, 'self_serve_onboarding'),
    'next', case when jsonb_array_length(v_orgs) = 0 then 'onboard' else 'workspace' end);
end;
$$;

create or replace function public.muster_onboard(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare u muster.users;
begin
  if not muster.has_flag(null, 'self_serve_onboarding') then
    raise exception 'self-serve onboarding is disabled' using errcode = '42501';
  end if;
  u := muster.ensure_user_from_auth();
  return muster.do_onboard(p, u.id);
end;
$$;

create or replace function public.muster_my_workspace()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare u muster.users;
begin
  u := muster.ensure_user_from_auth();
  return jsonb_build_object(
    'user', to_jsonb(u),
    'preferences', (select to_jsonb(pf) from muster.user_preferences pf where pf.user_id = u.id),
    'is_super_admin', u.role = 'super_admin',
    'platform_flags', muster.q_flags(null),
    'organizations', (
      select coalesce(jsonb_agg(muster.q_organization(m.organization_id) || jsonb_build_object('role', m.role) order by m.created_at), '[]'::jsonb)
      from muster.organization_members m where m.user_id = u.id));
end;
$$;

create or replace function public.muster_add_website(p_organization_id bigint, p_name text, p_url text, p_environment text default 'production', p_cadence_minutes integer default 1440)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if not muster.can_write_org(p_organization_id) then raise exception 'forbidden' using errcode = '42501'; end if;
  return muster.do_add_website(p_organization_id, p_name, p_url, p_environment, p_cadence_minutes, muster.current_user_id(), 'manual');
end;
$$;

create or replace function public.muster_request_scan(p_website_id bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_org bigint := muster.website_org(p_website_id);
begin
  if not muster.can_write_org(v_org) then raise exception 'forbidden' using errcode = '42501'; end if;
  if not muster.has_flag(v_org, 'manual_scans') then raise exception 'manual scans are disabled for this organization' using errcode = '42501'; end if;
  return muster.do_request_scan(p_website_id, muster.current_user_id(), null, 'manual');
end;
$$;

create or replace function public.muster_website_overview(p_website_id bigint)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not muster.is_org_member(muster.website_org(p_website_id)) then raise exception 'forbidden' using errcode = '42501'; end if;
  return muster.q_website_overview(p_website_id);
end;
$$;

create or replace function public.muster_findings(p_website_id bigint, p_statuses text[] default array['open','reopened'])
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not muster.is_org_member(muster.website_org(p_website_id)) then raise exception 'forbidden' using errcode = '42501'; end if;
  return muster.q_findings(p_website_id, p_statuses);
end;
$$;

create or replace function public.muster_scans(p_website_id bigint, p_limit integer default 20)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not muster.is_org_member(muster.website_org(p_website_id)) then raise exception 'forbidden' using errcode = '42501'; end if;
  return muster.q_scans(p_website_id, p_limit);
end;
$$;

create or replace function public.muster_sitrep(p_sitrep_id bigint)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_org bigint;
begin
  select organization_id into v_org from muster.sitreps where id = p_sitrep_id;
  if not muster.is_org_member(v_org) then raise exception 'forbidden' using errcode = '42501'; end if;
  return muster.q_sitrep(p_sitrep_id);
end;
$$;

create or replace function public.muster_latest_sitrep(p_website_id bigint)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not muster.is_org_member(muster.website_org(p_website_id)) then raise exception 'forbidden' using errcode = '42501'; end if;
  return muster.q_latest_sitrep(p_website_id);
end;
$$;

create or replace function public.muster_evidence(p_evidence_id bigint)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_org bigint;
begin
  select organization_id into v_org from muster.scan_evidence where id = p_evidence_id;
  if not muster.is_org_member(v_org) then raise exception 'forbidden' using errcode = '42501'; end if;
  return muster.q_evidence(p_evidence_id);
end;
$$;

create or replace function public.muster_compliance_posture(p_website_id bigint)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_org bigint := muster.website_org(p_website_id);
begin
  if not muster.is_org_member(v_org) then raise exception 'forbidden' using errcode = '42501'; end if;
  if not muster.has_flag(v_org, 'jurisdiction_advisor') then raise exception 'jurisdiction advisor is disabled for this organization' using errcode = '42501'; end if;
  return muster.q_compliance_posture(p_website_id);
end;
$$;

create or replace function public.muster_update_finding_status(p_finding_id bigint, p_status text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_org bigint;
begin
  select organization_id into v_org from muster.findings where id = p_finding_id;
  if not muster.can_write_org(v_org) then raise exception 'forbidden' using errcode = '42501'; end if;
  return muster.do_update_finding_status(p_finding_id, p_status, p_note, muster.current_user_id(), null);
end;
$$;

create or replace function public.muster_promote_finding_to_risk(p_finding_id bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_org bigint;
begin
  select organization_id into v_org from muster.findings where id = p_finding_id;
  if not muster.can_write_org(v_org) then raise exception 'forbidden' using errcode = '42501'; end if;
  if not muster.has_flag(v_org, 'promote_finding_to_risk') then raise exception 'feature disabled' using errcode = '42501'; end if;
  return muster.do_promote_finding(p_finding_id, muster.current_user_id(), null);
end;
$$;

create or replace function public.muster_update_scan_settings(p_website_id bigint, p_enabled boolean, p_cadence_minutes integer)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_org bigint := muster.website_org(p_website_id); v_min integer; st muster.website_scan_settings;
begin
  if not muster.can_write_org(v_org) then raise exception 'forbidden' using errcode = '42501'; end if;
  select p.scan_cadence_min_minutes into v_min from muster.organizations o join muster.plans p on p.plan = o.plan where o.id = v_org;
  insert into muster.website_scan_settings (website_id, enabled, cadence_minutes)
  values (p_website_id, coalesce(p_enabled, true), greatest(coalesce(p_cadence_minutes, 1440), v_min))
  on conflict (website_id) do update set enabled = excluded.enabled, cadence_minutes = excluded.cadence_minutes
  returning * into st;
  return to_jsonb(st);
end;
$$;

create or replace function public.muster_flags(p_organization_id bigint default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if p_organization_id is not null and not muster.is_org_member(p_organization_id) then raise exception 'forbidden' using errcode = '42501'; end if;
  return muster.q_flags(p_organization_id);
end;
$$;

create or replace function public.muster_brand(p_organization_id bigint, p_website_id bigint default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not muster.is_org_member(p_organization_id) then raise exception 'forbidden' using errcode = '42501'; end if;
  return muster.q_brand(p_organization_id, p_website_id);
end;
$$;

create or replace function public.muster_save_brand(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_org bigint := (p->>'organization_id')::bigint;
  v_site bigint := nullif(p->>'website_id', '')::bigint;
  v_existing bigint;
  b muster.brand_profiles;
begin
  if not muster.is_org_executive(v_org) then raise exception 'forbidden' using errcode = '42501'; end if;
  if not muster.has_flag(v_org, 'white_label') then raise exception 'white-label branding requires the Starter plan or higher' using errcode = '42501'; end if;
  if coalesce(p->>'brand_name', '') = '' then raise exception 'brand_name is required' using errcode = '22023'; end if;
  if v_site is not null and muster.website_org(v_site) is distinct from v_org then raise exception 'website does not belong to this organization' using errcode = '42501'; end if;
  if coalesce(p->>'custom_domain', '') <> '' and not muster.has_flag(v_org, 'custom_domain') then
    raise exception 'custom domains require the Pro plan' using errcode = '42501';
  end if;
  if coalesce((p->>'hide_muster_attribution')::boolean, false) and not muster.has_flag(v_org, 'hide_attribution') then
    raise exception 'attribution removal requires the Pro plan' using errcode = '42501';
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
$$;

create or replace function public.muster_save_preferences(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
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
$$;

create or replace function public.muster_invite_member(p_organization_id bigint, p_email text, p_role text)
returns jsonb language plpgsql security definer set search_path = '' as $$
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
$$;

-- Pending invites: stored as members with a placeholder user row is not allowed (auth_user_id unique, not null usable),
-- so pending invites live here and are claimed on first sign-in.
create table if not exists muster.pending_invites (
  id bigint generated by default as identity primary key,
  organization_id bigint not null references muster.organizations(id) on delete cascade,
  email varchar(320) not null,
  role varchar(32) not null check (role in ('executive','risk_owner','control_owner','contributor','viewer')),
  invited_by_id bigint references muster.users(id),
  created_at timestamptz not null default now(),
  claimed_at timestamptz,
  unique (organization_id, email)
);
alter table muster.pending_invites enable row level security;
drop policy if exists muster_invites_select on muster.pending_invites;
create policy muster_invites_select on muster.pending_invites for select to authenticated using (muster.is_org_member(organization_id));
drop policy if exists muster_invites_write on muster.pending_invites;
create policy muster_invites_write on muster.pending_invites for all to authenticated
  using (muster.is_org_executive(organization_id)) with check (muster.is_org_executive(organization_id));
grant select, insert, update, delete on muster.pending_invites to authenticated, service_role;

create or replace function public.muster_invite(p_organization_id bigint, p_email text, p_role text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r jsonb;
begin
  r := public.muster_invite_member(p_organization_id, p_email, p_role);
  if r->>'status' = 'pending_signup' then
    insert into muster.pending_invites (organization_id, email, role, invited_by_id)
    values (p_organization_id, lower(p_email), p_role, muster.current_user_id())
    on conflict (organization_id, email) do update set role = excluded.role, claimed_at = null;
  end if;
  return r;
end;
$$;

create or replace function public.muster_claim_invites()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare u muster.users; v_n integer := 0; inv record;
begin
  u := muster.ensure_user_from_auth();
  for inv in select * from muster.pending_invites where lower(email) = lower(u.email) and claimed_at is null loop
    insert into muster.organization_members (organization_id, user_id, role) values (inv.organization_id, u.id, inv.role)
    on conflict do nothing;
    update muster.pending_invites set claimed_at = now() where id = inv.id;
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('claimed', v_n);
end;
$$;

------------------------------------------------------------------------------
-- Public RPC: agents and API keys
------------------------------------------------------------------------------
create or replace function public.muster_create_api_key(p_organization_id bigint, p_agent_name text, p_kind text default 'customer_agent',
                                                        p_scopes text[] default array['read'], p_expires_at timestamptz default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
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
    'mcp_url', 'https://mgtmqucaldkaxvxglguw.supabase.co/functions/v1/muster-agent',
    'header', 'x-muster-api-key',
    'note', 'This key is shown once. Store it in your agent''s secret store.');
end;
$$;

create or replace function public.muster_revoke_api_key(p_key_id bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare k muster.api_keys;
begin
  select * into k from muster.api_keys where id = p_key_id;
  if k.id is null then raise exception 'key not found' using errcode = 'P0002'; end if;
  if k.organization_id is null then
    if not muster.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  elsif not muster.is_org_executive(k.organization_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  update muster.api_keys set revoked_at = now() where id = p_key_id;
  return jsonb_build_object('key_id', p_key_id, 'revoked', true);
end;
$$;

------------------------------------------------------------------------------
-- Public RPC: super admin console
------------------------------------------------------------------------------
create or replace function public.muster_admin_overview()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
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
      'cron', (select jsonb_build_object('active', j.active, 'schedule', j.schedule) from cron.job j where j.jobname = 'muster-scan-due')));
end;
$$;

create or replace function public.muster_admin_set_plan(p_organization_id bigint, p_plan text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare o muster.organizations;
begin
  if not muster.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  update muster.organizations set plan = p_plan, website_limit = (select website_limit from muster.plans where plan = p_plan)
  where id = p_organization_id returning * into o;
  if o.id is null then raise exception 'organization not found' using errcode = 'P0002'; end if;
  insert into muster.activity_events (organization_id, entity_type, entity_id, action, detail, actor_id)
  values (o.id, 'organization', o.id, 'Plan changed', p_plan, muster.current_user_id());
  return to_jsonb(o);
end;
$$;

create or replace function public.muster_admin_set_flag(p_key text, p_enabled boolean, p_organization_id bigint default null,
                                                        p_user_id bigint default null, p_reason text default null, p_expires_at timestamptz default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
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
$$;

create or replace function public.muster_admin_kill_switch(p_key text, p_on boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if not muster.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  update muster.feature_flags set kill_switch = p_on where key = p_key;
  return (select to_jsonb(f) from muster.feature_flags f where f.key = p_key);
end;
$$;

create or replace function public.muster_admin_set_user_role(p_email text, p_role text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare u muster.users;
begin
  if not muster.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_role not in ('user','admin','super_admin') then raise exception 'invalid role' using errcode = '22023'; end if;
  update muster.users set role = p_role where lower(email) = lower(p_email) returning * into u;
  if u.id is null then raise exception 'user not found' using errcode = 'P0002'; end if;
  return to_jsonb(u);
end;
$$;

create or replace function public.muster_admin_tenant(p_organization_id bigint)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not muster.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  return muster.q_organization(p_organization_id);
end;
$$;

------------------------------------------------------------------------------
-- Engine RPC (service_role only): used by the muster-scan edge function and pg_cron
------------------------------------------------------------------------------
create or replace function public.muster_engine_secret()
returns text language sql stable security definer set search_path = '' as $$
  select decrypted_secret from vault.decrypted_secrets where name = 'muster_cron_secret' limit 1;
$$;
create or replace function public.muster_engine_claim(p_scan_id bigint default null, p_limit integer default 3)
returns setof jsonb language sql security definer set search_path = '' as $$
  select muster.engine_claim(p_scan_id, p_limit);
$$;
create or replace function public.muster_engine_ingest(p_scan_id bigint, p_scan jsonb, p_evidence jsonb, p_findings jsonb)
returns jsonb language sql security definer set search_path = '' as $$
  select muster.engine_ingest(p_scan_id, p_scan, p_evidence, p_findings);
$$;
create or replace function public.muster_engine_fail(p_scan_id bigint, p_error text)
returns void language sql security definer set search_path = '' as $$
  select muster.engine_fail(p_scan_id, p_error);
$$;
create or replace function public.muster_engine_sitrep(p_scan_id bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_id bigint; v_org bigint;
begin
  select organization_id into v_org from muster.scans where id = p_scan_id;
  if not muster.has_flag(v_org, 'sitrep_generation') then
    return jsonb_build_object('skipped', true, 'reason', 'sitrep_generation flag off');
  end if;
  v_id := muster.generate_sitrep(p_scan_id);
  return (select jsonb_build_object('sitrep_id', s.id, 'headline', s.headline, 'posture_score', s.posture_score, 'posture_band', s.posture_band)
          from muster.sitreps s where s.id = v_id);
end;
$$;

-- Agent gateway: resolve a key, then dispatch a tool call with org scoping.
create or replace function public.muster_engine_resolve_api_key(p_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare k muster.api_keys; a muster.agents;
begin
  select * into k from muster.api_keys where key_hash = encode(sha256(convert_to(coalesce(p_key, ''), 'utf8')), 'hex');
  if k.id is null then return null; end if;
  if k.revoked_at is not null or (k.expires_at is not null and k.expires_at < now()) then return jsonb_build_object('error', 'key revoked or expired'); end if;
  select * into a from muster.agents where id = k.agent_id;
  if not a.active then return jsonb_build_object('error', 'agent inactive'); end if;
  if k.organization_id is not null and not muster.has_flag(k.organization_id, 'agent_api') then
    return jsonb_build_object('error', 'agent API disabled for this organization');
  end if;
  update muster.api_keys set last_used_at = now() where id = k.id;
  return jsonb_build_object('key_id', k.id, 'agent_id', a.id, 'agent_name', a.name, 'kind', a.kind,
    'organization_id', k.organization_id, 'scopes', to_jsonb(k.scopes));
end;
$$;

create or replace function muster.agent_tools()
returns jsonb language sql immutable set search_path = '' as $$
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
    jsonb_build_object('name', 'request_scan', 'scope', 'scan', 'description', 'Queue a scan for a website now. Returns the scan id; results arrive within a few minutes.',
      'inputSchema', jsonb_build_object('type', 'object', 'required', jsonb_build_array('website_id'), 'properties', jsonb_build_object('website_id', jsonb_build_object('type', 'integer')))),
    jsonb_build_object('name', 'update_finding_status', 'scope', 'write', 'description', 'Set a finding to open, accepted, false_positive, or resolved with a note.',
      'inputSchema', jsonb_build_object('type', 'object', 'required', jsonb_build_array('finding_id', 'status'), 'properties', jsonb_build_object('finding_id', jsonb_build_object('type', 'integer'), 'status', jsonb_build_object('type', 'string'), 'note', jsonb_build_object('type', 'string')))),
    jsonb_build_object('name', 'promote_finding_to_risk', 'scope', 'write', 'description', 'Create a risk register entry (with evidence link) from a finding.',
      'inputSchema', jsonb_build_object('type', 'object', 'required', jsonb_build_array('finding_id'), 'properties', jsonb_build_object('finding_id', jsonb_build_object('type', 'integer')))));
$$;

create or replace function public.muster_engine_agent_call(p_ctx jsonb, p_tool text, p_args jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
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
  elsif p_tool in ('website_overview','list_findings','latest_sitrep','compliance_posture','request_scan') then
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

create or replace function public.muster_engine_agent_tools()
returns jsonb language sql stable security definer set search_path = '' as $$
  select muster.agent_tools();
$$;

------------------------------------------------------------------------------
-- Execution grants
------------------------------------------------------------------------------
-- Internal muster.* functions created here: service_role only (the public wrappers run as owner).
revoke execute on all functions in schema muster from public, anon, authenticated;
grant execute on function
  muster.current_user_id(), muster.is_super_admin(), muster.org_role(bigint), muster.is_org_member(bigint),
  muster.can_write_org(bigint), muster.is_org_executive(bigint), muster.shares_org_with(bigint),
  muster.website_org(bigint), muster.risk_org(bigint), muster.control_org(bigint), muster.evidence_org(bigint),
  muster.remediation_org(bigint), muster.has_flag(bigint, text), muster.posture_score(bigint), muster.posture_band(integer),
  muster.severity_weight(text), muster.severity_rank(text), muster.finding_fingerprint(bigint, text, text, text)
  to authenticated;
grant execute on all functions in schema muster to service_role;

-- public.muster_*: revoke the default PUBLIC grant, then grant deliberately.
do $$
declare r record;
begin
  for r in select p.oid::regprocedure as sig, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'muster\_%' loop
    execute format('revoke execute on function %s from public, anon, authenticated', r.sig);
    execute format('grant execute on function %s to service_role', r.sig);
    if r.proname in ('muster_countries','muster_regions','muster_jurisdiction_advisory','muster_plans') then
      execute format('grant execute on function %s to anon, authenticated', r.sig);
    elsif r.proname not like 'muster\_engine\_%' then
      execute format('grant execute on function %s to authenticated', r.sig);
    end if;
  end loop;
end $$;

