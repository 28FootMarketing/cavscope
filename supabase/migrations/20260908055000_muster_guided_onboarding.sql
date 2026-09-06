-- Guided, server-enforced client onboarding: seven steps, each locked until
-- the previous one's gate is satisfied server-side. Applied directly against
-- this Supabase project in a separate session (remote migration
-- 20260906063133_muster_guided_onboarding) and reconstructed here from the
-- live schema so this repo matches production. See
-- 20260908060000_muster_onboarding_fixes.sql immediately after this file for
-- a security-grant hardening pass and two validation-bug fixes found on
-- review; that file's version of muster_onboarding_complete_step is the one
-- that ends up live -- this file is kept as-applied for history.
--
-- This is a second onboarding path alongside the existing self-serve one
-- (public.muster_onboard -> muster.do_onboard, still live, still used by the
-- self_serve_onboarding flag): onboard_client() is for a paid Stripe
-- checkout that invites the owner via Supabase Auth rather than having them
-- self-register. Nothing calls onboard_client() yet -- the muster-onboard
-- Stripe webhook that's meant to invoke it (from a Stripe checkout.session
-- event) hasn't been built. Until that exists this path is inert, by design.

alter table muster.websites add column if not exists verification_token varchar(64);
alter table muster.websites add column if not exists verified_at timestamptz;
alter table muster.organizations add column if not exists sitrep_recipients text[];

create table if not exists muster.onboarding_steps (
  id               bigint generated always as identity primary key,
  organization_id  bigint not null references muster.organizations(id) on delete cascade,
  step_no          integer not null,
  step_key         varchar(32) not null,
  title            text not null,
  payload          jsonb,
  completed_at     timestamptz,
  completed_by_id  bigint references muster.users(id),
  created_at       timestamptz not null default now(),
  unique (organization_id, step_key),
  unique (organization_id, step_no)
);
alter table muster.onboarding_steps enable row level security;
-- No policies: the table is reachable only through the SECURITY DEFINER
-- RPCs below, which resolve the caller and enforce step order themselves.

create or replace function muster.onboarding_seed(p_org_id bigint)
returns void language sql security definer set search_path to 'muster' as $function$
  insert into muster.onboarding_steps (organization_id, step_no, step_key, title) values
    (p_org_id, 1, 'account',       'Secure your account'),
    (p_org_id, 2, 'organization',  'Confirm your organization'),
    (p_org_id, 3, 'website',       'Verify you own the website'),
    (p_org_id, 4, 'risk_appetite', 'Set your risk appetite'),
    (p_org_id, 5, 'team',          'Name the risk owner and SITREP recipients'),
    (p_org_id, 6, 'first_scan',    'Run your first scan'),
    (p_org_id, 7, 'sitrep',        'Read your first SITREP')
  on conflict do nothing;
$function$;

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
  values (p_org_name, v_plan, v_website_limit, 'in_progress', v_user_id, v_user_id,
          (select stage from muster.commercial_pricing where stripe_price_id = p_stripe_price_id))
  returning id into v_org_id;

  insert into muster.organization_members (organization_id, user_id, role) values (v_org_id, v_user_id, 'owner');

  insert into muster.websites (name, url, owner_id, organization_id, verification_token)
  values (p_website_name, p_website_url, v_user_id, v_org_id, 'muster-' || encode(gen_random_bytes(12), 'hex'))
  returning id into v_site_id;

  -- scanning stays disabled until the client verifies ownership (step 3)
  insert into muster.website_scan_settings (website_id, enabled, cadence_minutes, next_run_at) values (v_site_id, false, v_cadence, null);

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
  where u.auth_user_id = auth.uid() and m.role = 'owner' and o.onboarding_status <> 'complete'
  order by o.created_at desc limit 1;
$function$;

create or replace function muster.mark_website_verified(p_website_id bigint)
returns void language sql security definer set search_path to 'muster' as $function$
  update muster.websites set verified_at = now() where id = p_website_id and verified_at is null;
$function$;

create or replace function public.muster_mark_website_verified(p_website_id bigint)
returns void language sql security definer set search_path to 'muster', 'public' as $function$
  select muster.mark_website_verified(p_website_id);
$function$;
-- Locked to service_role only (see 20260908060000): the muster-verify-site
-- Edge Function is the sole legitimate caller, after it has actually fetched
-- the site and found the verification meta tag.

create or replace function public.muster_onboarding_state()
returns jsonb language plpgsql security definer set search_path to 'muster', 'public' as $function$
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
end $function$;

-- muster_onboarding_complete_step: created here as originally applied
-- (review_cadence 'semiannual', no high >= critical check); superseded
-- immediately by the corrected create-or-replace in
-- 20260908060000_muster_onboarding_fixes.sql.
create or replace function public.muster_onboarding_complete_step(p_step_key varchar, p_payload jsonb default '{}'::jsonb)
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
      if (p_payload->>'critical_threshold')::int < 0 or (p_payload->>'high_threshold')::int < 0 then raise exception 'thresholds must be >= 0'; end if;
      if p_payload->>'review_cadence' not in ('monthly','quarterly','semiannual','annual') then raise exception 'review_cadence invalid'; end if;
      update muster.risk_appetites set statement = p_payload->>'statement',
        critical_threshold = (p_payload->>'critical_threshold')::int, high_threshold = (p_payload->>'high_threshold')::int,
        review_cadence = p_payload->>'review_cadence', owner_id = v_user, updated_at = now(),
        next_review_at = now() + case p_payload->>'review_cadence' when 'monthly' then interval '1 month'
          when 'quarterly' then interval '3 months' when 'semiannual' then interval '6 months' else interval '12 months' end
      where organization_id = v_org;

    when 'team' then
      if jsonb_array_length(coalesce(p_payload->'sitrep_recipients','[]'::jsonb)) < 1 then raise exception 'at least one SITREP recipient email required'; end if;
      update muster.organizations set risk_owner_id = v_user,
        sitrep_recipients = array(select jsonb_array_elements_text(p_payload->'sitrep_recipients')) where id = v_org;
      insert into muster.pending_invites (organization_id, email, role, invited_by_id)
      select v_org, e, 'member', v_user from jsonb_array_elements_text(coalesce(p_payload->'invites','[]'::jsonb)) e
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

-- As originally applied: no revoke/grant statements ran for any of the three
-- public.muster_onboarding_* / muster_mark_website_verified functions above,
-- so they kept Postgres's default EXECUTE-to-PUBLIC grant -- anon included.
-- 20260908060000_muster_onboarding_fixes.sql is the migration that actually
-- tightens this.
