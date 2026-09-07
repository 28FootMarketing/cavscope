-- MUSTER: agency/tenant client-pricing fields.
-- 28 Foot Systems licenses the MUSTER platform itself to the tenant (unrelated to this table).
-- This is the reverse direction: a white-labeled tenant records what THEY charge THEIR OWN
-- clients for platform access, and a link to whatever payment platform they use to collect it
-- (Stripe Payment Link, PayPal.me, an invoicing tool, anything). MUSTER stores this for the
-- tenant's own reference and branding; it never processes or touches that money.

alter table muster.brand_profiles
  add column if not exists client_price_amount numeric(10,2),
  add column if not exists client_price_cadence varchar(16),
  add column if not exists client_payment_url varchar(1024),
  add column if not exists client_pricing_note text;

alter table muster.brand_profiles drop constraint if exists brand_profiles_client_price_cadence_check;
alter table muster.brand_profiles add constraint brand_profiles_client_price_cadence_check
  check (client_price_cadence is null or client_price_cadence in ('monthly','annual','one_time','custom'));

alter table muster.brand_profiles drop constraint if exists brand_profiles_client_price_amount_check;
alter table muster.brand_profiles add constraint brand_profiles_client_price_amount_check
  check (client_price_amount is null or client_price_amount >= 0);

------------------------------------------------------------------------------
-- public.muster_save_brand: now also persists the tenant's own client pricing
------------------------------------------------------------------------------
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
