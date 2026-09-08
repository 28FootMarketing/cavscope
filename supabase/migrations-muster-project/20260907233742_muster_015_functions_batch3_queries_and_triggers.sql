-- MUSTER function layer, batch 3 of 3. Copies the remaining 24 muster.* bodies
-- from the live catalog on mgtmqucaldkaxvxglguw. With this, muster.* is at 58/58.
--
-- ONE DELIBERATE DIVERGENCE from source, and it is not a transcription slip:
-- muster.do_request_scan() hardcodes the Supabase URL it POSTs to in order to
-- kick the scan engine. Copied verbatim, this project would fire every scan at
-- the OLD project's muster-scan function -- scans queued here, executed there,
-- results written there. The URL below points at this project. Everything else
-- in this migration is byte-identical to source and checksum-verified.
--
-- Also carried forward UNCHANGED, and wrong on both projects: do_add_website()
-- has doubled backslashes in its URL regex ('\\.') and in its regexp_replace
-- backreference ('\\1'). '\\.' requires a literal backslash in the URL, so the
-- validation rejects every valid address -- proven by direct test, not inferred.
-- Fixed on both projects in the next migration, deliberately separate so this
-- one stays a verifiable copy.
set check_function_bodies = off;

CREATE OR REPLACE FUNCTION muster.do_request_scan(p_website_id bigint, p_user_id bigint, p_agent_id bigint, p_trigger text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
      url := 'https://hjowfnzpomzxazmzywxw.supabase.co/functions/v1/muster-scan',
      headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_anon, 'x-muster-secret', v_secret),
      body := jsonb_build_object('scan_id', v_scan_id),
      timeout_milliseconds := 120000);
  exception when others then
    insert into muster.activity_events (organization_id, entity_type, entity_id, action, detail)
    values (v_org, 'scan', v_scan_id, 'Engine kick deferred', left(SQLERRM, 500));
  end;

  return jsonb_build_object('scan_id', v_scan_id, 'status', 'queued', 'deduplicated', false);
end;
$function$
;

CREATE OR REPLACE FUNCTION muster.q_compliance_posture(p_website_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
    'disclaimer', 'Statuses reflect scanner evidence only. \"clear\" means no open scanner finding maps to the law; it is not a certification of compliance.');
end;
$function$
;

CREATE OR REPLACE FUNCTION muster.do_add_website(p_org bigint, p_name text, p_url text, p_environment text, p_cadence_minutes integer, p_user_id bigint, p_trigger text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_count integer;
  v_limit integer;
  v_min_cadence integer;
  v_url text := trim(p_url);
  v_website_id bigint;
  v_scan jsonb;
begin
  if v_url !~* '^https?://[a-z0-9.-]+\\.[a-z]{2,}(:[0-9]+)?(/.*)?$' then
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
  values (left(coalesce(nullif(trim(p_name), ''), regexp_replace(v_url, '^https?://([^/]+).*$', '\\1')), 160), left(v_url, 512),
          coalesce(p_environment, 'production'), p_user_id, p_org)
  returning id into v_website_id;

  insert into muster.website_scan_settings (website_id, cadence_minutes, next_run_at)
  values (v_website_id, greatest(coalesce(p_cadence_minutes, 1440), v_min_cadence), now() + interval '1 day');

  insert into muster.activity_events (organization_id, entity_type, entity_id, action, detail, actor_id)
  values (p_org, 'website', v_website_id, 'Website added', v_url, p_user_id);

  v_scan := muster.do_request_scan(v_website_id, p_user_id, null, p_trigger);
  return jsonb_build_object('website_id', v_website_id, 'url', v_url, 'first_scan', v_scan);
end;
$function$
;

CREATE OR REPLACE FUNCTION muster.q_brand(p_org bigint, p_website_id bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  b muster.brand_profiles%rowtype;
  v_wl boolean := muster.has_flag(p_org, 'white_label_enabled');
  v_hide boolean := muster.has_flag(p_org, 'hide_attribution');
  v_domain boolean := muster.has_flag(p_org, 'custom_domain_enabled');
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
$function$
;

CREATE OR REPLACE FUNCTION muster.q_organization(p_org bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION muster.q_website_summary(p_website_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION muster.has_flag(p_org bigint, p_key text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  f    muster.feature_flags%rowtype;
  v_uid bigint := muster.current_user_id();
  v_ov  boolean;
  v_plan_rank integer;
  v_min_rank integer;
begin
  select * into f from muster.feature_flags where key = p_key;
  if not found then return false; end if;
  if f.kill_switch then return false; end if;

  if v_uid is not null then
    select enabled into v_ov from muster.feature_flag_overrides
    where flag_key = p_key and user_id = v_uid and (expires_at is null or expires_at > now());
    if found then return v_ov; end if;
  end if;
  if p_org is not null then
    select enabled into v_ov from muster.feature_flag_overrides
    where flag_key = p_key and organization_id = p_org and user_id is null and (expires_at is null or expires_at > now());
    if found then return v_ov; end if;
    if f.plan_minimum is not null then
      select p.rank into v_plan_rank from muster.organizations o join muster.plans p on p.plan = o.plan where o.id = p_org;
      select rank into v_min_rank from muster.plans where plan = f.plan_minimum;
      if coalesce(v_plan_rank, -1) < coalesce(v_min_rank, 0) then return false; end if;
    end if;
  end if;
  return f.default_enabled;
end;
$function$
;

CREATE OR REPLACE FUNCTION muster.q_findings(p_website_id bigint, p_statuses text[] DEFAULT ARRAY['open'::text, 'reopened'::text])
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION muster.ensure_user_from_auth()
 RETURNS muster.users
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION muster.do_update_finding_status(p_finding_id bigint, p_status text, p_note text, p_user_id bigint, p_agent_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION muster.q_search_evidence(p_website_id bigint, p_query_embedding vector, p_limit integer DEFAULT 10, p_threshold double precision DEFAULT 0.6)
 RETURNS TABLE(evidence_id bigint, finding_ids bigint[], chunk_text text, similarity double precision)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'muster'
AS $function$
  with scored as (
    select
      se.id as evidence_id,
      fe.finding_id,
      ee.chunk_text,
      (1 - pow(ee.embedding <-> p_query_embedding, 2) / 4)::float as similarity
    from muster.evidence_embeddings ee
    join muster.scan_evidence se on se.id = ee.evidence_id
    join muster.finding_evidence fe on fe.evidence_id = se.id
    join muster.findings f on f.id = fe.finding_id
    where ee.website_id = p_website_id
      and f.status in ('open', 'reopened')
  )
  select
    s.evidence_id,
    array_agg(distinct s.finding_id) as finding_ids,
    s.chunk_text,
    max(s.similarity) as similarity
  from scored s
  where s.similarity >= p_threshold
  group by s.evidence_id, s.chunk_text
  order by similarity desc
  limit p_limit;
$function$
;

CREATE OR REPLACE FUNCTION muster.q_search_findings(p_website_id bigint, p_query_embedding vector, p_limit integer DEFAULT 10, p_threshold double precision DEFAULT 0.6)
 RETURNS TABLE(finding_id bigint, title text, rule_id text, severity text, chunk_text text, similarity double precision)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'muster'
AS $function$
  select
    f.id,
    f.title,
    f.rule_id,
    f.severity,
    fe.chunk_text,
    (1 - pow(fe.embedding <-> p_query_embedding, 2) / 4)::float as similarity
  from muster.finding_embeddings fe
  join muster.findings f on f.id = fe.finding_id
  where fe.website_id = p_website_id
    and f.status in ('open', 'reopened')
    and (1 - pow(fe.embedding <-> p_query_embedding, 2) / 4)::float >= p_threshold
  order by similarity desc
  limit p_limit;
$function$
;

CREATE OR REPLACE FUNCTION muster.onboarding_first_scan_done()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'muster'
AS $function$
begin
  if new.finished_at is not null and old.finished_at is null then
    update muster.onboarding_steps s set completed_at = now(), payload = jsonb_build_object('scan_id', new.id)
    where s.organization_id = new.organization_id and s.step_key = 'first_scan' and s.completed_at is null
      and not exists (select 1 from muster.onboarding_steps p where p.organization_id = s.organization_id and p.step_no < 6 and p.completed_at is null);
  end if;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION muster.q_website_overview(p_website_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select muster.q_website_summary(p_website_id)
    || jsonb_build_object(
         'compliance', muster.q_compliance_posture(p_website_id),
         'brand', muster.q_brand(muster.website_org(p_website_id), p_website_id),
         'findings', muster.q_findings(p_website_id, array['open','reopened']),
         'recent_scans', muster.q_scans(p_website_id, 10));
$function$
;

CREATE OR REPLACE FUNCTION muster.admin_sandbox_org()
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_org bigint;
begin
  select id into v_org from muster.organizations where is_admin_sandbox limit 1;
  if v_org is not null then return v_org; end if;
  insert into muster.organizations (name, plan, country_code, onboarding_status, is_admin_sandbox)
  values ('MUSTER Admin — Ad Hoc Scans', 'internal', 'US', 'complete', true)
  returning id into v_org;
  return v_org;
end;
$function$
;

CREATE OR REPLACE FUNCTION muster.queue_evidence_for_reembedding()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if new.excerpt is distinct from old.excerpt or new.headers is distinct from old.headers then
    insert into muster.embedding_queue (entity_type, entity_id)
    values ('evidence', new.id)
    on conflict (entity_type, entity_id)
      do update set processed_at = null, created_at = now();
  end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION muster.queue_finding_for_reembedding()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if new.title is distinct from old.title or new.detail is distinct from old.detail then
    insert into muster.embedding_queue (entity_type, entity_id)
    values ('finding', new.id)
    on conflict (entity_type, entity_id)
      do update set processed_at = null, created_at = now();
  end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION muster.q_scans(p_website_id bigint, p_limit integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce(jsonb_agg(to_jsonb(s) order by s.created_at desc), '[]'::jsonb)
  from (select * from muster.scans where website_id = p_website_id order by created_at desc limit greatest(1, least(p_limit, 100))) s;
$function$
;

CREATE OR REPLACE FUNCTION muster.q_evidence(p_evidence_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select to_jsonb(e) || jsonb_build_object('finding_ids',
    (select coalesce(jsonb_agg(fe.finding_id), '[]'::jsonb) from muster.finding_evidence fe where fe.evidence_id = e.id))
  from muster.scan_evidence e where e.id = p_evidence_id;
$function$
;

CREATE OR REPLACE FUNCTION muster.queue_evidence_for_embedding()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  insert into muster.embedding_queue (entity_type, entity_id)
  values ('evidence', new.id)
  on conflict (entity_type, entity_id)
    do update set processed_at = null, created_at = now();
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION muster.queue_finding_for_embedding()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  insert into muster.embedding_queue (entity_type, entity_id)
  values ('finding', new.id)
  on conflict (entity_type, entity_id)
    do update set processed_at = null, created_at = now();
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION muster.q_latest_sitrep(p_website_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select to_jsonb(s) from muster.sitreps s where s.website_id = p_website_id order by s.generated_at desc limit 1;
$function$
;

CREATE OR REPLACE FUNCTION muster.q_flags(p_org bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce(jsonb_object_agg(f.key, muster.has_flag(p_org, f.key)), '{}'::jsonb) from muster.feature_flags f;
$function$
;

CREATE OR REPLACE FUNCTION muster.q_sitrep(p_sitrep_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select to_jsonb(s) from muster.sitreps s where s.id = p_sitrep_id;
$function$
;
