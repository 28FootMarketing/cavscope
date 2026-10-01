-- Subscription cancellation: a customer whose Stripe subscription ends stops
-- holding the plan it paid for.
--
-- Until now nothing consumed customer.subscription.deleted, so a cancelled
-- customer kept their plan until someone changed it by hand. The self-serve path
-- records a pending grant keyed by email; do_onboard claims it when the buyer
-- creates their organization. The grant never recorded WHICH organization
-- claimed it, so a cancelling subscription had nothing to point at.
--
-- This migration:
--   1. adds pending_commercial_grants.organization_id (set when a grant is
--      claimed) and cancelled_at (set when its subscription ends);
--   2. makes do_onboard record the claiming organization and ignore a cancelled
--      grant -- the two edits are marked "CHANGED" below, the rest is the live
--      definition unchanged;
--   3. makes cavscope_engine_record_commercial_grant clear cancelled_at when the
--      same email buys again before claiming, so a re-purchase is not born
--      cancelled;
--   4. adds public.cavscope_engine_cancel_subscription(text), called only by the
--      muster-stripe-webhook edge function with the service role.
--
-- What cancelling does: an organization still on the plan its grant gave it goes
-- back to 'trial' with the trial website limit and no commercial stage. Nothing
-- is deleted: websites, findings, reports and the team stay readable. An
-- organization whose plan a super admin has since moved by hand is left alone and
-- the skip is written to its activity log, because overwriting a deliberate
-- decision with an automatic one is the worse failure. A grant whose organization
-- was never created is voided so it cannot be claimed later. The function is
-- idempotent: Stripe retries, and a second delivery changes nothing.
--
-- No backfill: pending_commercial_grants held no rows when this was written
-- (read from the live table), so no applied grant lacks an organization_id.
--
-- Engine RPC rule (CLAUDE.md): the new function is revoked from anon and
-- authenticated BY NAME. Supabase default privileges grant EXECUTE on every new
-- public function to both; `revoke from public` does not remove that.

alter table cavscope.pending_commercial_grants
  add column if not exists organization_id bigint references cavscope.organizations(id) on delete set null,
  add column if not exists cancelled_at timestamptz;

create index if not exists pending_commercial_grants_subscription_idx
  on cavscope.pending_commercial_grants (stripe_subscription_id)
  where stripe_subscription_id is not null;

CREATE OR REPLACE FUNCTION cavscope.do_onboard(p jsonb, p_user_id bigint)
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
  v_creator_email text;
begin
  if v_name = '' then raise exception 'org_name is required' using errcode = '22023'; end if;
  if not exists (select 1 from cavscope.countries where code = v_country) then
    raise exception 'country_code must be an ISO 3166-1 alpha-2 code' using errcode = '22023';
  end if;
  if v_region is not null and not exists (select 1 from cavscope.jurisdictions where code = v_country || '-' || v_region) then
    raise exception 'region_code % is not known for country %', v_region, v_country using errcode = '22023';
  end if;
  select count(*) into v_owned from cavscope.organizations where created_by_id = p_user_id;
  if v_owned >= 5 and not cavscope.is_super_admin() then
    raise exception 'organization limit reached for this account' using errcode = '42501';
  end if;

  insert into cavscope.organizations (name, industry, risk_owner_id, plan, country_code, region_code, timezone, website_limit,
    onboarding_status, created_by_id)
  values (v_name, left(nullif(p->>'industry', ''), 120), p_user_id, 'trial', v_country, v_region, v_tz,
    (select website_limit from cavscope.plans where plan = 'trial'), 'profile', p_user_id)
  returning id into v_org_id;

  insert into cavscope.organization_members (organization_id, user_id, role) values (v_org_id, p_user_id, 'executive');

  select g.* into v_grant
  from cavscope.pending_commercial_grants g
  join cavscope.users u on lower(u.email) = g.email
  where u.id = p_user_id and g.applied_at is null
    and g.cancelled_at is null  -- CHANGED: a grant whose subscription already ended grants nothing
  order by g.created_at desc
  limit 1;

  if v_grant.id is not null then
    update cavscope.organizations
    set plan = v_grant.plan,
        website_limit = (select website_limit from cavscope.plans where plan = v_grant.plan),
        commercial_stage = v_grant.stage
    where id = v_org_id;
    update cavscope.pending_commercial_grants set applied_at = now(), organization_id = v_org_id where id = v_grant.id;  -- CHANGED: record which organization claimed it
    insert into cavscope.activity_events (organization_id, entity_type, entity_id, action, detail, actor_id)
    values (v_org_id, 'organization', v_org_id, 'commercial_plan_applied',
      format('Applied pending Stripe grant: plan=%s stage=%s stripe_subscription_id=%s', v_grant.plan, v_grant.stage, coalesce(v_grant.stripe_subscription_id, 'n/a')),
      p_user_id);
  end if;

  insert into cavscope.risk_appetites (organization_id, statement, critical_threshold, high_threshold, review_cadence, next_review_at, owner_id)
  values (v_org_id, 'No open critical website findings. High findings remediated within 30 days.', 0, 2, 'quarterly', now() + interval '90 days', p_user_id);

  if v_brand is not null and coalesce(v_brand->>'brand_name', '') <> '' then
    insert into cavscope.brand_profiles (organization_id, brand_name, brand_mark, eyebrow, primary_color, accent_color, logo_url,
      support_email, report_signoff_name, report_signoff_title, welcome_message, tone, created_by_id)
    values (v_org_id, left(v_brand->>'brand_name', 80),
      upper(left(coalesce(nullif(v_brand->>'brand_mark', ''), left(v_brand->>'brand_name', 2)), 4)),
      left(coalesce(nullif(v_brand->>'eyebrow', ''), 'Website Assurance'), 80),
      coalesce(nullif(v_brand->>'primary_color', ''), '#36e2c9'), coalesce(nullif(v_brand->>'accent_color', ''), '#f5b942'),
      nullif(v_brand->>'logo_url', ''), nullif(v_brand->>'support_email', ''), nullif(v_brand->>'report_signoff_name', ''),
      nullif(v_brand->>'report_signoff_title', ''), nullif(v_brand->>'welcome_message', ''),
      coalesce(nullif(v_brand->>'tone', ''), 'executive'), p_user_id);
  end if;

  update cavscope.user_preferences set default_organization_id = v_org_id,
    preferred_name = coalesce(nullif(p->>'preferred_name', ''), preferred_name)
  where user_id = p_user_id;

  insert into cavscope.activity_events (organization_id, entity_type, entity_id, action, detail, actor_id)
  values (v_org_id, 'organization', v_org_id, 'Organization created (self-serve onboarding)',
    'Jurisdiction ' || v_country || coalesce('-' || v_region, ''), p_user_id);

  if coalesce(p->>'website_url', '') <> '' then
    update cavscope.organizations set onboarding_status = 'website' where id = v_org_id;
    v_site := cavscope.do_add_website(v_org_id, p->>'website_name', p->>'website_url', coalesce(p->>'environment', 'production'), 1440, p_user_id, 'onboarding');
    update cavscope.organizations set onboarding_status = 'complete', onboarding_completed_at = now() where id = v_org_id;
  end if;

  select email into v_creator_email from cavscope.users where id = p_user_id;
  if v_creator_email is not null then
    insert into cavscope.notification_outbox
      (organization_id, category, entity_type, entity_id, severity, subject, body_text, recipient_emails)
    values (
      v_org_id, 'workspace_created', 'organization', v_org_id, 'info',
      format('[CavScope] Your workspace is ready: %s', v_name),
      format(E'%s is set up in CavScope.\n\n%s\n\nSign in to your CavScope workspace to invite your team and review your jurisdiction obligations.\n',
        v_name,
        case when v_site is not null
          then format('Your first website, %s, has been added and its first scan is running -- the SITREP will appear in your workspace shortly.', coalesce(v_site->>'url', 'your site'))
          else 'Add your first website from the workspace to start your first assurance scan.'
        end),
      array[v_creator_email]
    )
    on conflict (entity_type, entity_id, category) do nothing;
  end if;

  return jsonb_build_object(
    'organization', cavscope.q_organization(v_org_id),
    'website', v_site,
    'advisory', cavscope.q_jurisdiction_advisory(v_country, v_region, true),
    'next_steps', jsonb_build_array(
      case when v_site is null then 'Add your first website to start the scan.' else 'Your first scan is running. The SITREP will appear in a few minutes.' end,
      'Invite a risk owner and a control owner from Settings.',
      'Review the jurisdiction obligations mapped to your scan evidence.',
      'Set your brand profile if you deliver reports under your own name.'));
end;
$function$;

CREATE OR REPLACE FUNCTION public.cavscope_engine_record_commercial_grant(p_email text, p_tier text, p_stage text, p_stripe_customer_id text, p_stripe_subscription_id text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_plan varchar;
begin
  select maps_to_plan into v_plan from cavscope.commercial_pricing where tier = p_tier and stage = p_stage;
  if v_plan is null then
    raise exception 'no commercial_pricing row for tier % stage %', p_tier, p_stage using errcode = '22023';
  end if;
  insert into cavscope.pending_commercial_grants (email, plan, stage, stripe_customer_id, stripe_subscription_id)
  values (lower(p_email), v_plan, p_stage, p_stripe_customer_id, p_stripe_subscription_id)
  on conflict (lower(email)) where applied_at is null
  do update set plan = excluded.plan, stage = excluded.stage, stripe_customer_id = excluded.stripe_customer_id,
    stripe_subscription_id = excluded.stripe_subscription_id, created_at = now(),
    cancelled_at = null;  -- CHANGED: buying again before claiming replaces a cancelled grant
end;
$function$;

create or replace function public.cavscope_engine_cancel_subscription(p_stripe_subscription_id text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_grant record;
  v_org record;
  v_trial_limit integer;
begin
  if coalesce(p_stripe_subscription_id, '') = '' then
    raise exception 'p_stripe_subscription_id is required' using errcode = '22023';
  end if;

  select g.* into v_grant
  from cavscope.pending_commercial_grants g
  where g.stripe_subscription_id = p_stripe_subscription_id
  order by g.id desc
  limit 1
  for update;

  -- Not one of ours (another brand shares this Stripe account), or never recorded.
  if v_grant.id is null then
    return jsonb_build_object('outcome', 'unknown_subscription');
  end if;

  if v_grant.cancelled_at is not null then
    return jsonb_build_object('outcome', 'already_cancelled');
  end if;

  update cavscope.pending_commercial_grants set cancelled_at = now() where id = v_grant.id;

  -- Paid, but the buyer never created an organization: nothing to downgrade, and
  -- the voided grant can no longer be claimed.
  if v_grant.organization_id is null then
    return jsonb_build_object('outcome', 'grant_voided');
  end if;

  select o.id, o.plan into v_org from cavscope.organizations o where o.id = v_grant.organization_id for update;
  if v_org.id is null then
    return jsonb_build_object('outcome', 'organization_gone');
  end if;

  if v_org.plan is distinct from v_grant.plan then
    insert into cavscope.activity_events (organization_id, entity_type, entity_id, action, detail, actor_id)
    values (v_org.id, 'organization', v_org.id, 'commercial_plan_cancellation_skipped',
      format('Stripe subscription %s ended, but the plan is %s, not the %s it was granted; left as set by hand.',
        p_stripe_subscription_id, v_org.plan, v_grant.plan),
      null);
    return jsonb_build_object('outcome', 'plan_changed_by_hand_left_alone', 'organization_id', v_org.id);
  end if;

  select website_limit into v_trial_limit from cavscope.plans where plan = 'trial';

  update cavscope.organizations
  set plan = 'trial', website_limit = v_trial_limit, commercial_stage = null
  where id = v_org.id;

  insert into cavscope.activity_events (organization_id, entity_type, entity_id, action, detail, actor_id)
  values (v_org.id, 'organization', v_org.id, 'commercial_plan_cancelled',
    format('Stripe subscription %s ended: plan %s returned to trial. Websites, findings and reports are kept.',
      p_stripe_subscription_id, v_grant.plan),
    null);

  return jsonb_build_object('outcome', 'downgraded', 'organization_id', v_org.id, 'from_plan', v_grant.plan);
end;
$function$;

revoke all on function public.cavscope_engine_cancel_subscription(text) from public, anon, authenticated;
grant execute on function public.cavscope_engine_cancel_subscription(text) to service_role;
