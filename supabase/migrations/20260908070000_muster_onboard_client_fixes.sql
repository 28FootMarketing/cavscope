-- muster.onboard_client() and its dependents had never actually been run --
-- the Stripe webhook that's meant to call it doesn't exist yet, so this
-- entire codepath shipped in 20260908055000/060000 without ever executing.
-- Running it directly against production (test rows created then deleted;
-- see session record) surfaced four bugs that would have broken every real
-- invocation from the very first statement:
--
-- 1. organization_members.role only allows ('executive','risk_owner',
--    'control_owner','contributor','viewer') -- 'owner' isn't one of them.
--    onboard_client() inserted role='owner' for the founding member, so the
--    very first INSERT in the function always failed the check constraint.
--    muster.do_onboard (the working self-serve path) already establishes
--    'executive' as this schema's equivalent of "founding/owner member" --
--    matched here. muster.onboarding_caller() filtered on role = 'owner' for
--    the same reason and is fixed to match.
-- 2. organizations.onboarding_status only allows ('started','profile',
--    'website','first_scan','complete') -- onboard_client() wrote
--    'in_progress', which isn't one of them either. do_onboard uses
--    'profile' as its first value for the self-serve flow; 'started' is the
--    correct first value here since the finer-grained muster.onboarding_steps
--    table (not this column) is what actually gates the guided sequence.
-- 3. gen_random_bytes() is part of pgcrypto, installed into the `extensions`
--    schema on this project -- not on this function's search_path (muster,
--    public). Every other caller of it in this codebase already qualifies it
--    as extensions.gen_random_bytes(); onboard_client() called it bare.
-- 4. website_scan_settings.next_run_at is not-null; onboard_client() passed
--    null explicitly. Left off the insert instead so the column default
--    (now()) applies -- harmless, since the cron sweep filters on `enabled`
--    (false here until the client verifies ownership) before ever looking
--    at next_run_at.
--
-- A fifth, same-shaped bug in muster_onboarding_complete_step's 'team' step:
-- it inserted pending_invites.role = 'member', which the table's check
-- constraint (same five values as organization_members) also rejects.
-- Defaults optional teammate invites to 'contributor' instead.

create or replace function muster.onboard_client(
  p_auth_user_id uuid, p_email varchar, p_name text, p_org_name varchar, p_stripe_price_id varchar,
  p_website_name varchar, p_website_url varchar, p_included_client_orgs integer default null)
returns table(organization_id bigint, website_id bigint, resolved_plan varchar)
language plpgsql security definer set search_path to 'muster', 'public' as $function$
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

  -- scanning stays disabled until the client verifies ownership (step 3). next_run_at is
  -- not-null on this table but irrelevant while enabled=false -- the cron sweep filters on
  -- enabled first -- so it's left at its default (now()) rather than passed explicitly.
  insert into muster.website_scan_settings (website_id, enabled, cadence_minutes) values (v_site_id, false, v_cadence);

  insert into muster.risk_appetites (organization_id, statement, critical_threshold, high_threshold, review_cadence, owner_id, next_review_at)
  values (v_org_id, 'Default risk appetite pending client review.', 1, 3, 'quarterly', v_user_id, now() + interval '30 days');

  perform muster.onboarding_seed(v_org_id);

  insert into muster.activity_events (organization_id, entity_type, entity_id, action, detail, actor_id)
  values (v_org_id, 'organization', v_org_id, 'onboarding_started', 'Provisioned via Stripe price ' || p_stripe_price_id, v_user_id);

  return query select v_org_id, v_site_id, v_plan;
end $function$;

create or replace function muster.onboarding_caller()
returns table(user_id bigint, org_id bigint)
language sql security definer set search_path to 'muster' as $function$
  select u.id, m.organization_id
  from muster.users u join muster.organization_members m on m.user_id = u.id
  join muster.organizations o on o.id = m.organization_id
  where u.auth_user_id = auth.uid() and m.role = 'executive' and o.onboarding_status <> 'complete'
  order by o.created_at desc limit 1;
$function$;

create or replace function public.muster_onboarding_complete_step(p_step_key character varying, p_payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'muster', 'public' as $function$
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
end $function$;
