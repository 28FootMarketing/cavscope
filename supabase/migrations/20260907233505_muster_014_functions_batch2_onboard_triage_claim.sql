-- MUSTER function layer, batch 2 of 3. Copied from the live catalog on
-- mgtmqucaldkaxvxglguw, byte-for-byte; each is checksum-verified against source
-- after apply.
--
-- NOTE for a later pass, deliberately NOT changed here so this migration stays a
-- faithful copy: muster.autotriage() hardcodes
-- https://app.muster.28footsystems.com/ in the alert body. That host still
-- resolves, but the product's home is app.muster.partners/app now. Fix it on
-- BOTH projects in one migration once this project is at parity, so the two do
-- not drift again.
set check_function_bodies = off;

CREATE OR REPLACE FUNCTION muster.do_onboard(p jsonb, p_user_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_org_id bigint;
  v_name text := left(trim(coalesce(p->>'org_name', '')), 160);
  v_country text := upper(left(coalesce(p->>'country_code', ''), 2));
  v_region text := nullif(upper(left(coalesce(p->>'region_code', ''), 8)), '');
  v_tz text := coalesce(nullif(p->>'timezone', ''), 'America/New_York');
  v_owned integer;
  v_site jsonb;
  v_brand jsonb := p->'brand';
  v_grant record;
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

  select g.* into v_grant
  from muster.pending_commercial_grants g
  join muster.users u on lower(u.email) = g.email
  where u.id = p_user_id and g.applied_at is null
  order by g.created_at desc
  limit 1;

  if v_grant.id is not null then
    update muster.organizations
    set plan = v_grant.plan,
        website_limit = (select website_limit from muster.plans where plan = v_grant.plan),
        commercial_stage = v_grant.stage
    where id = v_org_id;
    update muster.pending_commercial_grants set applied_at = now() where id = v_grant.id;
    insert into muster.activity_events (organization_id, entity_type, entity_id, action, detail, actor_id)
    values (v_org_id, 'organization', v_org_id, 'commercial_plan_applied',
      format('Applied pending Stripe grant: plan=%s stage=%s stripe_subscription_id=%s', v_grant.plan, v_grant.stage, coalesce(v_grant.stripe_subscription_id, 'n/a')),
      p_user_id);
  end if;

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
$function$
;

CREATE OR REPLACE FUNCTION muster.autotriage()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'muster', 'public'
AS $function$
declare f record; rid bigint; opened int := 0; closed int := 0; drifted int := 0; sc record; queued int := 0;
  v_org record; v_recipients text[];
begin
  for sc in select s.id from muster.scans s left join muster.scan_postprocess p on p.scan_id = s.id
            where s.status='complete' and p.drift_done_at is null order by s.id limit 50
  loop drifted := drifted + muster.drift_detect(sc.id); end loop;

  for f in
    select fi.*, w.owner_id, w.name as website_name, w.url as website_url,
           r.category as rule_category, r.remediation, r.plain_english
    from muster.findings fi
    join muster.websites w on w.id = fi.website_id
    left join muster.scan_rules r on r.rule_id = fi.rule_id
    where fi.status in ('open','reopened') and fi.risk_id is null and fi.severity in ('critical','high','medium')
  loop
    insert into muster.risks (website_id, title, description, category, source, severity, status, inherent_score, residual_score, treatment, treatment_plan, owner_id, identified_at, target_date)
    values (f.website_id, f.title, coalesce(f.plain_english, f.detail), coalesce(f.rule_category,'governance'),
      case coalesce(f.rule_category,'') when 'privacy' then 'privacy_assessment' when 'accessibility' then 'accessibility_audit' when 'third_party' then 'vendor_assessment' else 'security_scan' end,
      f.severity, 'open',
      case f.severity when 'critical' then 20 when 'high' then 15 else 9 end,
      case f.severity when 'critical' then 20 when 'high' then 15 else 9 end,
      'mitigate', f.remediation, f.owner_id, coalesce(f.first_seen_at, now()),
      now() + case f.severity when 'critical' then interval '7 days' when 'high' then interval '30 days' else interval '90 days' end)
    returning id into rid;
    insert into muster.remediation_actions (risk_id, title, description, status, progress, owner_id, due_date, escalation_status)
    values (rid, 'Fix: ' || f.title, coalesce(f.remediation, f.detail), 'not_started', 0, f.owner_id,
      now() + case f.severity when 'critical' then interval '7 days' when 'high' then interval '30 days' else interval '90 days' end, 'none');
    update muster.findings set risk_id = rid where id = f.id;
    insert into muster.activity_events (organization_id, entity_type, entity_id, action, detail)
    values (f.organization_id, 'risk', rid, 'auto_opened', format('Opened from finding %s (%s)', f.rule_id, f.severity));
    opened := opened + 1;

    if f.severity in ('critical','high') then
      select o.* into v_org from muster.organizations o where o.id = f.organization_id;
      if v_org.critical_alerts_enabled then
        select coalesce(array_agg(distinct u.email), '{}')
          into v_recipients
          from muster.organization_members om
          join muster.users u on u.id = om.user_id
          where om.organization_id = f.organization_id
            and om.role in ('executive','risk_owner');
        if array_length(v_recipients, 1) > 0 then
          insert into muster.notification_outbox
            (organization_id, category, entity_type, entity_id, severity, subject, body_text, recipient_emails)
          values (
            f.organization_id, 'risk_opened', 'risk', rid, f.severity,
            format('[MUSTER] New %s risk on %s: %s', upper(f.severity), f.website_name, f.title),
            format(E'MUSTER opened a new %s-severity risk on %s (%s).\n\nFinding: %s\n%s\n\nRemediation: %s\n\nView full detail: https://app.muster.28footsystems.com/\n',
              f.severity, f.website_name, f.website_url, f.title, coalesce(f.plain_english, f.detail), coalesce(f.remediation, 'See dashboard for recommended remediation.')),
            v_recipients
          )
          on conflict (entity_type, entity_id, category) do nothing;
          queued := queued + 1;
        else
          insert into muster.activity_events (organization_id, entity_type, entity_id, action, detail)
          values (f.organization_id, 'risk', rid, 'alert_skipped_no_recipient',
            'No org member with role executive/risk_owner -- critical/high risk alert not queued');
        end if;
      end if;
    end if;
  end loop;

  for f in
    select fi.id, fi.risk_id, fi.organization_id from muster.findings fi join muster.risks r on r.id = fi.risk_id
    where fi.status = 'resolved' and r.status in ('open','in_progress')
  loop
    update muster.risks set status='mitigated', residual_score = least(residual_score, 4), updated_at = now() where id = f.risk_id;
    update muster.remediation_actions set status='verified', progress=100, verified_at=now(), status_update='Verified by rescan', updated_at=now()
      where risk_id = f.risk_id and status <> 'verified';
    insert into muster.activity_events (organization_id, entity_type, entity_id, action, detail)
    values (f.organization_id, 'risk', f.risk_id, 'auto_mitigated', 'Finding no longer detected by scan engine');
    closed := closed + 1;
  end loop;

  update muster.risks r set status='open', updated_at=now()
    from muster.findings fi where fi.risk_id = r.id and fi.status='reopened' and r.status in ('mitigated','closed');

  return jsonb_build_object('drift_events', drifted, 'risks_opened', opened, 'risks_mitigated', closed, 'alerts_queued', queued);
end $function$
;

CREATE OR REPLACE FUNCTION muster.engine_claim(p_scan_id bigint DEFAULT NULL::bigint, p_limit integer DEFAULT 3)
 RETURNS SETOF jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  -- Time out scans that never reported back.
  update muster.scans set status = 'failed', finished_at = now(),
    error_message = coalesce(error_message, 'Engine timeout: no result within 10 minutes')
  where status = 'running' and started_at < now() - interval '10 minutes';

  if p_scan_id is not null then
    return query
      with claimed as (
        update muster.scans s set status = 'running', started_at = now()
        where s.id = p_scan_id and s.status = 'queued'
        returning s.*
      )
      select jsonb_build_object('scan_id', c.id, 'website_id', c.website_id, 'organization_id', c.organization_id,
        'target_url', c.target_url, 'website_name', w.name, 'trigger', c.trigger,
        'max_pages', coalesce(st.max_pages, 1))
      from claimed c join muster.websites w on w.id = c.website_id
      left join muster.website_scan_settings st on st.website_id = c.website_id;
    return;
  end if;

  -- Scheduled: websites whose next_run_at is due and have nothing in flight.
  return query
    with due as (
      select st.website_id, w.organization_id, w.url, w.name, st.max_pages
      from muster.website_scan_settings st
      join muster.websites w on w.id = st.website_id
      where st.enabled and st.next_run_at <= now()
        and not exists (select 1 from muster.scans x where x.website_id = w.id and x.status in ('queued','running'))
      order by st.next_run_at
      limit p_limit
      for update of st skip locked
    ), bumped as (
      update muster.website_scan_settings st set next_run_at = now() + (st.cadence_minutes || ' minutes')::interval
      from due where st.website_id = due.website_id
      returning st.website_id
    ), created as (
      insert into muster.scans (organization_id, website_id, trigger, status, target_url, started_at)
      select d.organization_id, d.website_id, 'scheduled', 'running', d.url, now() from due d
      returning *
    )
    select jsonb_build_object('scan_id', c.id, 'website_id', c.website_id, 'organization_id', c.organization_id,
      'target_url', c.target_url, 'website_name', d.name, 'trigger', c.trigger, 'max_pages', d.max_pages)
    from created c join due d on d.website_id = c.website_id;

  -- Queued manual/api scans whose HTTP kick failed to arrive.
  return query
    with stale as (
      update muster.scans s set status = 'running', started_at = now()
      where s.id in (
        select id from muster.scans where status = 'queued' and queued_at < now() - interval '2 minutes'
        order by queued_at limit p_limit for update skip locked)
      returning s.*
    )
    select jsonb_build_object('scan_id', c.id, 'website_id', c.website_id, 'organization_id', c.organization_id,
      'target_url', c.target_url, 'website_name', w.name, 'trigger', c.trigger,
      'max_pages', coalesce(st.max_pages, 1))
    from stale c join muster.websites w on w.id = c.website_id
    left join muster.website_scan_settings st on st.website_id = c.website_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION muster.drift_detect(p_scan_id bigint)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'muster', 'public'
AS $function$
declare s record; prev_id bigint; n int := 0; r record;
  volatile text[] := array['date','etag','last-modified','age','expires','cf-ray','cf-cache-status','x-request-id','x-vercel-id','x-vercel-cache','x-amz-cf-id','x-amz-cf-pop','x-cache','x-served-by','x-timer','via','set-cookie','content-length','x-nf-request-id','x-railway-request-id','server-timing','report-to','nel','x-github-request-id','x-fastly-request-id','x-envoy-upstream-service-time','x-powered-by','alt-svc','x-frame-options-report'];
begin
  select id, website_id, organization_id into s from muster.scans where id = p_scan_id and status = 'complete';
  if not found then return 0; end if;
  select id into prev_id from muster.scans where website_id = s.website_id and status='complete' and id < s.id order by id desc limit 1;
  if prev_id is not null then
    for r in
      select a.kind, a.url, b.sha256 as before_sha, a.sha256 as after_sha, b.http_status as before_status, a.http_status as after_status,
             (a.kind = 'header_set' and (a.headers - volatile) is distinct from (b.headers - volatile)) as header_diff
      from muster.scan_evidence a
      join muster.scan_evidence b on b.scan_id = prev_id and b.kind = a.kind
      where a.scan_id = s.id and a.kind in ('http_response','header_set','robots_txt','sitemap','security_txt')
    loop
      if r.kind = 'header_set' then
        if not r.header_diff and r.after_status is not distinct from r.before_status then continue; end if;
      elsif r.after_sha is not distinct from r.before_sha and r.after_status is not distinct from r.before_status then continue;
      end if;
      insert into muster.change_events (organization_id, website_id, scan_id, prev_scan_id, kind, url, before_sha, after_sha, before_status, after_status, summary, severity)
      values (s.organization_id, s.website_id, s.id, prev_id, r.kind, r.url, r.before_sha, r.after_sha, r.before_status, r.after_status,
        case when r.after_status is distinct from r.before_status then format('%s: HTTP %s -> %s', r.kind, r.before_status, r.after_status)
             else format('%s changed since scan #%s', r.kind, prev_id) end,
        case when r.after_status is distinct from r.before_status and coalesce(r.after_status,0) >= 400 then 'critical'
             when r.kind = 'header_set' then 'medium' else 'info' end);
      insert into muster.activity_events (organization_id, entity_type, entity_id, action, detail)
      values (s.organization_id, 'website', s.website_id, 'drift_detected', format('%s changed (scan #%s vs #%s)', r.kind, s.id, prev_id));
      n := n + 1;
    end loop;
  end if;
  insert into muster.scan_postprocess(scan_id, drift_done_at) values (s.id, now()) on conflict (scan_id) do update set drift_done_at = now();
  return n;
end $function$
;

CREATE OR REPLACE FUNCTION muster.do_promote_finding(p_finding_id bigint, p_user_id bigint, p_agent_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION muster.onboard_client(p_auth_user_id uuid, p_email character varying, p_name text, p_org_name character varying, p_stripe_price_id character varying, p_website_name character varying, p_website_url character varying, p_included_client_orgs integer DEFAULT NULL::integer)
 RETURNS TABLE(organization_id bigint, website_id bigint, resolved_plan character varying)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'muster', 'public'
AS $function$
declare v_user_id bigint; v_plan varchar; v_website_limit integer; v_cadence integer; v_org_id bigint; v_site_id bigint;
begin
  select cp.maps_to_plan into v_plan from muster.commercial_pricing cp where cp.stripe_price_id = p_stripe_price_id;
  if v_plan is null then raise exception 'onboard_client: no commercial_pricing row for stripe_price_id %', p_stripe_price_id; end if;
  select pl.website_limit, pl.scan_cadence_min_minutes into v_website_limit, v_cadence from muster.plans pl where pl.plan = v_plan;
  if p_included_client_orgs is not null then v_website_limit := p_included_client_orgs; end if;

  insert into muster.users (auth_user_id, name, email, login_method) values (p_auth_user_id, p_name, p_email, 'invite')
  on conflict (auth_user_id) do update set name = excluded.name, email = excluded.email returning id into v_user_id;

  insert into muster.organizations (name, plan, website_limit, onboarding_status, created_by_id, risk_owner_id, commercial_stage)
  values (p_org_name, v_plan, v_website_limit, 'started', v_user_id, v_user_id,
          (select stage from muster.commercial_pricing where stripe_price_id = p_stripe_price_id))
  returning id into v_org_id;

  insert into muster.organization_members (organization_id, user_id, role) values (v_org_id, v_user_id, 'executive');

  insert into muster.websites (name, url, owner_id, organization_id, verification_token)
  values (p_website_name, p_website_url, v_user_id, v_org_id, 'muster-' || encode(extensions.gen_random_bytes(12), 'hex'))
  returning id into v_site_id;

  insert into muster.website_scan_settings (website_id, enabled, cadence_minutes) values (v_site_id, false, v_cadence);

  insert into muster.risk_appetites (organization_id, statement, critical_threshold, high_threshold, review_cadence, owner_id, next_review_at)
  values (v_org_id, 'Default risk appetite pending client review.', 1, 3, 'quarterly', v_user_id, now() + interval '30 days');

  perform muster.onboarding_seed(v_org_id);

  insert into muster.activity_events (organization_id, entity_type, entity_id, action, detail, actor_id)
  values (v_org_id, 'organization', v_org_id, 'onboarding_started', 'Provisioned via Stripe price ' || p_stripe_price_id, v_user_id);

  return query select v_org_id, v_site_id, v_plan;
end $function$
;

CREATE OR REPLACE FUNCTION muster.q_jurisdiction_advisory(p_country text, p_region text, p_full boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$
;
