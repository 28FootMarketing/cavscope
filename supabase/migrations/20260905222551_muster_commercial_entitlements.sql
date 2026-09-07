-- Reconciles the finalized public commercial tiers (MUSTER / MUSTER Partner /
-- MUSTER Enterprise) with the existing muster.feature_flags entitlement system.
--
-- Only 2 organizations exist in this project today, both plan='internal'
-- (28FS's own workspaces) -- zero real paying customers on trial/starter/pro/
-- enterprise. Renaming and retightening these flags carries no risk of
-- breaking a live subscription.
--
-- Real defect fixed here: 'white_label' defaulted to true at plan_minimum
-- 'starter', meaning every org reaching the Starter technical plan got
-- white-label branding automatically. The finalized public pricing explicitly
-- reserves white-labeling for MUSTER Partner only -- the base MUSTER tier
-- must not include it. Left alone, the backend would silently grant a paid
-- Partner-tier feature to base-tier customers.
--
-- Judgment call made here, not handed down explicitly: MUSTER Partner is
-- reconciled to require at least the existing 'pro' technical plan rank
-- (the rank that already carries agent_api / custom_domain / hide_attribution
-- -- the other "advanced" capabilities). This is the smallest change that
-- resolves the conflict without inventing a new plan rank; flag for review.
--
-- Not done here, intentionally: muster.plans and muster.organizations.plan
-- are untouched. Which technical plan rank a purchase of "MUSTER" vs "MUSTER
-- Partner" actually provisions is a separate decision belonging to the real
-- provisioning/checkout flow, which does not exist yet.

-- Rename + retighten the two existing flags this conflict touches.
update muster.feature_flags
set key = 'white_label_enabled',
    name = 'White-label branding',
    description = 'Reports, portal, and customer-facing pages display the tenant''s own branding instead of MUSTER''s. MUSTER Partner tier and above.',
    plan_minimum = 'pro',
    default_enabled = true
where key = 'white_label';

update muster.feature_flags
set key = 'custom_domain_enabled',
    default_enabled = true
where key = 'custom_domain';

-- New, additive-only entitlement primitives named per the finalized pricing
-- spec. None of these five have a bespoke RPC enforcement point yet -- the
-- underlying UI/data model for client-org counts, the partner dashboard, and
-- Enterprise-scope features doesn't exist yet either. has_flag() against
-- these keys works correctly today; nothing currently calls it for them.
insert into muster.feature_flags (key, name, description, scope, default_enabled, plan_minimum, kill_switch) values
  ('commercial_use_enabled', 'Commercial / partner usage rights',
    'Permits using MUSTER as part of paid services delivered to external clients. Distinct from white-labeling: this is the right to charge clients, not the ability to rebrand the product for them.',
    'organization', true, 'pro', false),
  ('client_management_enabled', 'Client organization management',
    'Grants the ability to create and manage client organizations under one Partner account.',
    'organization', true, 'pro', false),
  ('custom_branding_enabled', 'Custom brand identity',
    'Grants access to brand_profiles customization (logo, colors, name). Currently always granted alongside white_label_enabled -- kept as a separate key per the product spec in case the two need to diverge later (e.g. custom colors without full white-label).',
    'organization', true, 'pro', false),
  ('partner_dashboard_enabled', 'Partner dashboard',
    'Grants access to the multi-client Partner dashboard view.',
    'organization', true, 'pro', false),
  ('enterprise_enabled', 'Enterprise features',
    'Gates Enterprise-scope features (multi-department access, custom governance frameworks, RBAC, advanced audit logging). Actual scope is set per contract during discovery -- this flag is the technical gate once an Enterprise org is provisioned, not a promise every listed Enterprise feature ships automatically.',
    'organization', true, 'enterprise', false)
on conflict (key) do nothing;

-- Update the two RPCs that referenced the old flag keys by string literal.
create or replace function muster.q_brand(p_org bigint, p_website_id bigint default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
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
$$;

------------------------------------------------------------------------------
-- Durable pricing source of truth (database side). index.html's PRICING JS
-- object remains the source the static landing page actually renders from --
-- this table is what the eventual Stripe/billing build reads from, so the
-- same numbers aren't hand-copied a third time. stripe_price_id is nullable
-- and stays null until a real Stripe account and Price objects exist.
------------------------------------------------------------------------------
create table if not exists muster.commercial_pricing (
  tier varchar(20) not null check (tier in ('muster', 'muster_partner')),
  stage varchar(10) not null check (stage in ('seed', 'fruit')),
  monthly_price_cents integer not null check (monthly_price_cents >= 0),
  included_client_orgs integer,
  additional_org_price_cents integer check (additional_org_price_cents is null or additional_org_price_cents >= 0),
  stripe_price_id varchar(255),
  updated_at timestamptz not null default now(),
  primary key (tier, stage)
);

insert into muster.commercial_pricing (tier, stage, monthly_price_cents, included_client_orgs, additional_org_price_cents) values
  ('muster', 'seed', 9700, null, null),
  ('muster', 'fruit', 19700, null, null),
  ('muster_partner', 'seed', 19700, 5, 3900),
  ('muster_partner', 'fruit', 49700, 10, 4900)
on conflict (tier, stage) do update set
  monthly_price_cents = excluded.monthly_price_cents,
  included_client_orgs = excluded.included_client_orgs,
  additional_org_price_cents = excluded.additional_org_price_cents,
  updated_at = now();
