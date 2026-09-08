-- PRD-003: Stripe self-serve checkout for the base MUSTER tier only.
-- MUSTER Partner/Enterprise stay on the GHL sales-assisted path
-- (BLOCKERS-AND-DECISIONS.md B-1). This does NOT resurrect
-- muster.onboard_client (dead, buggy -- see 20260906012143's header
-- comment) -- it reuses the already-verified, already-live self-serve
-- onboarding path (muster_onboard -> muster.do_onboard, FIND-009) by
-- teaching it to recognize a Stripe payment made before the user ever
-- signs up, instead of building a second, parallel onboarding function.
--
-- Flow: visitor pays via a Stripe Payment Link (metadata: tier, stage) ->
-- muster-stripe-webhook verifies the event, invites the auth user if new,
-- and records a pending grant keyed by email -> the SAME onboarding wizard
-- every self-serve trial user already goes through (app.html, "no human
-- in the loop") picks up the pending grant the moment the org is created
-- and applies the paid plan instead of leaving it on trial.

create table muster.pending_commercial_grants (
  id bigint generated always as identity primary key,
  email varchar(320) not null,
  plan varchar not null references muster.plans(plan),
  stage varchar(10) not null check (stage in ('seed','fruit')),
  stripe_customer_id text,
  stripe_subscription_id text,
  created_at timestamptz not null default now(),
  applied_at timestamptz
);

-- At most one *unapplied* grant per email -- if someone somehow pays twice
-- before completing onboarding once, the second payment's webhook updates
-- the same pending row rather than creating an ambiguous second one.
create unique index pending_commercial_grants_email_unapplied
  on muster.pending_commercial_grants (lower(email)) where applied_at is null;

alter table muster.pending_commercial_grants enable row level security;
-- No policies: same deny-by-default pattern as every other muster_engine_*
-- backed table this session. Access only via the SECURITY DEFINER
-- functions below.

create or replace function public.muster_engine_record_commercial_grant(
  p_email text, p_tier text, p_stage text, p_stripe_customer_id text, p_stripe_subscription_id text
) returns void
language plpgsql security definer set search_path = '' as $$
declare v_plan varchar;
begin
  select maps_to_plan into v_plan from muster.commercial_pricing where tier = p_tier and stage = p_stage;
  if v_plan is null then
    raise exception 'no commercial_pricing row for tier % stage %', p_tier, p_stage using errcode = '22023';
  end if;
  insert into muster.pending_commercial_grants (email, plan, stage, stripe_customer_id, stripe_subscription_id)
  values (lower(p_email), v_plan, p_stage, p_stripe_customer_id, p_stripe_subscription_id)
  on conflict (lower(email)) where applied_at is null
  do update set plan = excluded.plan, stage = excluded.stage, stripe_customer_id = excluded.stripe_customer_id,
    stripe_subscription_id = excluded.stripe_subscription_id, created_at = now();
end;
$$;
revoke all on function public.muster_engine_record_commercial_grant(text, text, text, text, text) from public, anon, authenticated;
grant execute on function public.muster_engine_record_commercial_grant(text, text, text, text, text) to service_role;

-- Extend the existing self-serve onboarding function: right after the
-- organization + membership are created (and before the first website is
-- added, so any plan-derived website_limit check sees the right plan),
-- check for a pending Stripe grant matching this user's email and apply
-- it instead of leaving the org on 'trial'.
create or replace function muster.do_onboard(p jsonb, p_user_id bigint)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
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

  -- PRD-003: apply a pending Stripe self-serve grant, if this user's email
  -- has one, instead of leaving the org on trial.
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
$function$;

-- Backfill the real Stripe price ids for the base muster tier now that
-- they exist (both created live -- prod_VCwq3MBRwc16WC). MUSTER Partner
-- rows stay null: that tier is still GHL sales-assisted (B-1).
update muster.commercial_pricing set stripe_price_id = 'price_1UCWx0JijfcmbDDBLEFrn3Et' where tier = 'muster' and stage = 'seed';
update muster.commercial_pricing set stripe_price_id = 'price_1UCWx0JijfcmbDDBKaHbJyGW' where tier = 'muster' and stage = 'fruit';
