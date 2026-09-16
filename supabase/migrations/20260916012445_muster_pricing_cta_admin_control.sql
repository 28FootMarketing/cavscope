-- MUSTER: super-admin control over the public pricing page's CTA destinations.
--
-- Three things were wrong before this migration:
--
--   1. index.html's MUSTER Partner CTA -- the only CTA on the only card the
--      page shows by default -- was the hardcoded placeholder host
--      forms.your-ghl-domain.example.com, which does not resolve. Every click
--      on the public pricing page died at DNS.
--   2. app.html's admin console has had three "show this tier publicly"
--      toggles wired to public.muster_admin_set_pricing_visibility() since the
--      pricing panel was built. That function has never existed on this
--      project, so every click threw PGRST202. muster_public_pricing()
--      returned no `visible` key either, so index.html fell back to its
--      Partner-only default and the two states happened to agree -- which is
--      why nobody noticed the toggles were inert.
--   3. Every other CTA destination (both base-tier Stripe Payment Links, the
--      self-serve pause, all three contact mailtos) was a constant in page
--      source, so changing where a button points meant a deploy.
--
-- After this migration the whole CTA surface is one row in
-- muster.pricing_settings, read by muster_public_pricing() (anon-callable, for
-- index.html) and muster_admin_overview() (super admin, for the console), and
-- written only through super-admin RPCs that validate what they are given.
-- The page constants stay as a last-resort fallback for when the RPC itself is
-- unreachable.

-- ---------------------------------------------------------------------------
-- 1. Destination validation, server side.
--
-- The same rule index.html's isRealHttpsUrl() applies in the browser, enforced
-- where it cannot be bypassed. A destination is either absolute https to a
-- real host, or a mailto. RFC 2606 / RFC 6761 reserve example.com and the
-- .example/.test/.invalid/.localhost TLDs; the 'your-' prefix catches the
-- swap-me-in hostnames placeholders are conventionally written as. Null and
-- empty both mean "unset", which is valid -- the page falls back.
-- ---------------------------------------------------------------------------

create or replace function muster.is_valid_cta_destination(p_url text)
returns boolean
language sql
immutable
set search_path to ''
as $$
  select case
    when p_url is null or btrim(p_url) = '' then true
    when p_url ~* '^mailto:[^@[:space:]]+@[a-z0-9.-]+\.[a-z]{2,}(\?[^[:space:]]*)?$' then true
    when p_url ~* '^https://' then (
      select h <> ''
         and h !~ '[[:space:]]'
         and h not like 'your-%'
         and h not like '%.your-%'
         and h !~ '(^|\.)example\.(com|net|org)$'
         and h !~ '\.(example|test|invalid|localhost)$'
         and h <> 'localhost'
      from (select lower(coalesce(substring(p_url from '^https://([^/?#]+)'), '')) as h) t
    )
    else false
  end;
$$;

comment on function muster.is_valid_cta_destination(text) is
  'True if p_url is usable as a public CTA destination: absolute https to a non-placeholder host, or a mailto, or unset. Mirrors isRealHttpsUrl() in index.html.';

-- ---------------------------------------------------------------------------
-- 2. The control surface itself.
--
-- pricing_settings is a singleton (id boolean primary key, always true).
-- Visibility defaults match what index.html has been shipping: Partner only.
-- Every *_url column starts null, meaning "page falls back to its constant".
-- The two base-tier links are seeded with the live Payment Links that are
-- already in page source and already carry metadata {tier: muster, stage}.
-- The Partner link columns stay null on purpose: no Partner price exists in
-- Stripe (commercial_pricing.stripe_price_id is null for muster_partner on
-- both stages), and a base-tier link put here would undercharge the buyer and
-- make muster-stripe-webhook grant them the wrong tier.
-- ---------------------------------------------------------------------------

alter table muster.pricing_settings
  add column if not exists show_muster              boolean not null default false,
  add column if not exists show_muster_partner      boolean not null default true,
  add column if not exists show_enterprise          boolean not null default false,
  add column if not exists muster_self_serve_paused boolean not null default true,
  add column if not exists muster_seed_checkout_url    text,
  add column if not exists muster_fruit_checkout_url   text,
  add column if not exists muster_contact_url          text,
  add column if not exists partner_seed_checkout_url   text,
  add column if not exists partner_fruit_checkout_url  text,
  add column if not exists partner_intake_url          text,
  add column if not exists partner_contact_url         text,
  add column if not exists enterprise_contact_url      text;

update muster.pricing_settings set
  muster_seed_checkout_url  = coalesce(muster_seed_checkout_url,  'https://buy.stripe.com/eVqbJ26yL2hw3gL2x3gIo0t'),
  muster_fruit_checkout_url = coalesce(muster_fruit_checkout_url, 'https://buy.stripe.com/bJeeVe5uHaO2bNhb3zgIo0u'),
  muster_contact_url        = coalesce(muster_contact_url,        'mailto:sales@28footsystems.com?subject=MUSTER%20Interest'),
  partner_contact_url       = coalesce(partner_contact_url,       'mailto:sales@28footsystems.com?subject=MUSTER%20Partner%20Inquiry'),
  enterprise_contact_url    = coalesce(enterprise_contact_url,    'mailto:sales@28footsystems.com?subject=MUSTER%20Enterprise%20Inquiry')
where id = true;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'pricing_settings_cta_destinations_valid') then
    alter table muster.pricing_settings
      add constraint pricing_settings_cta_destinations_valid check (
            muster.is_valid_cta_destination(muster_seed_checkout_url)
        and muster.is_valid_cta_destination(muster_fruit_checkout_url)
        and muster.is_valid_cta_destination(muster_contact_url)
        and muster.is_valid_cta_destination(partner_seed_checkout_url)
        and muster.is_valid_cta_destination(partner_fruit_checkout_url)
        and muster.is_valid_cta_destination(partner_intake_url)
        and muster.is_valid_cta_destination(partner_contact_url)
        and muster.is_valid_cta_destination(enterprise_contact_url)
      );
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Public read. Adds `visible` and `cta`; existing keys unchanged, so the
--    pages' current reads keep working.
-- ---------------------------------------------------------------------------

create or replace function public.muster_public_pricing()
returns jsonb
language sql
stable
security definer
set search_path to ''
as $$
  select jsonb_build_object(
    'current_stage', s.current_stage,
    'muster', (select jsonb_build_object('monthly_price_cents', p.monthly_price_cents)
      from muster.commercial_pricing p where p.tier = 'muster' and p.stage = s.current_stage),
    'muster_partner', (select jsonb_build_object('monthly_price_cents', p.monthly_price_cents,
        'included_client_orgs', p.included_client_orgs, 'additional_org_price_cents', p.additional_org_price_cents)
      from muster.commercial_pricing p where p.tier = 'muster_partner' and p.stage = s.current_stage),
    'visible', jsonb_build_object(
      'muster', s.show_muster,
      'muster_partner', s.show_muster_partner,
      'enterprise', s.show_enterprise),
    'cta', jsonb_build_object(
      'muster_self_serve_paused', s.muster_self_serve_paused,
      'muster_seed_checkout_url', s.muster_seed_checkout_url,
      'muster_fruit_checkout_url', s.muster_fruit_checkout_url,
      'muster_contact_url', s.muster_contact_url,
      'partner_seed_checkout_url', s.partner_seed_checkout_url,
      'partner_fruit_checkout_url', s.partner_fruit_checkout_url,
      'partner_intake_url', s.partner_intake_url,
      'partner_contact_url', s.partner_contact_url,
      'enterprise_contact_url', s.enterprise_contact_url)
  )
  from muster.pricing_settings s where s.id = true;
$$;

-- ---------------------------------------------------------------------------
-- 4. Super-admin writers.
-- ---------------------------------------------------------------------------

-- The function app.html has been calling since the pricing panel was built.
-- Refuses to hide the last visible tier: an empty pricing section is a broken
-- page, and telling the admin so beats silently overriding them (which is what
-- index.html's client-side guard does today).
create or replace function public.muster_admin_set_pricing_visibility(p_tier text, p_visible boolean)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_show_muster boolean;
  v_show_partner boolean;
  v_show_enterprise boolean;
begin
  if not muster.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_tier not in ('muster', 'muster_partner', 'enterprise') then
    raise exception 'tier must be muster, muster_partner or enterprise' using errcode = '22023';
  end if;
  if p_visible is null then
    raise exception 'visible must be true or false' using errcode = '22023';
  end if;

  select
    case when p_tier = 'muster'         then p_visible else s.show_muster end,
    case when p_tier = 'muster_partner' then p_visible else s.show_muster_partner end,
    case when p_tier = 'enterprise'     then p_visible else s.show_enterprise end
  into v_show_muster, v_show_partner, v_show_enterprise
  from muster.pricing_settings s where s.id = true;

  if not (v_show_muster or v_show_partner or v_show_enterprise) then
    raise exception 'at least one pricing tier must stay visible' using errcode = '23514';
  end if;

  update muster.pricing_settings set
    show_muster = v_show_muster,
    show_muster_partner = v_show_partner,
    show_enterprise = v_show_enterprise,
    updated_at = now()
  where id = true;

  return public.muster_public_pricing();
end;
$$;

-- Sets one CTA destination. p_url null or blank clears it, which makes the
-- page fall back to its in-source constant.
create or replace function public.muster_admin_set_checkout_url(p_key text, p_url text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_url text;
begin
  if not muster.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_key not in (
    'muster_seed_checkout_url', 'muster_fruit_checkout_url', 'muster_contact_url',
    'partner_seed_checkout_url', 'partner_fruit_checkout_url', 'partner_intake_url',
    'partner_contact_url', 'enterprise_contact_url'
  ) then
    raise exception 'unknown CTA destination key: %', p_key using errcode = '22023';
  end if;

  v_url := nullif(btrim(coalesce(p_url, '')), '');

  if not muster.is_valid_cta_destination(v_url) then
    raise exception 'destination must be absolute https to a real host, or a mailto: address'
      using errcode = '22023';
  end if;

  update muster.pricing_settings set
    muster_seed_checkout_url   = case when p_key = 'muster_seed_checkout_url'   then v_url else muster_seed_checkout_url end,
    muster_fruit_checkout_url  = case when p_key = 'muster_fruit_checkout_url'  then v_url else muster_fruit_checkout_url end,
    muster_contact_url         = case when p_key = 'muster_contact_url'         then v_url else muster_contact_url end,
    partner_seed_checkout_url  = case when p_key = 'partner_seed_checkout_url'  then v_url else partner_seed_checkout_url end,
    partner_fruit_checkout_url = case when p_key = 'partner_fruit_checkout_url' then v_url else partner_fruit_checkout_url end,
    partner_intake_url         = case when p_key = 'partner_intake_url'         then v_url else partner_intake_url end,
    partner_contact_url        = case when p_key = 'partner_contact_url'        then v_url else partner_contact_url end,
    enterprise_contact_url     = case when p_key = 'enterprise_contact_url'     then v_url else enterprise_contact_url end,
    updated_at = now()
  where id = true;

  return public.muster_public_pricing();
end;
$$;

-- Un-pausing base-tier self-serve is interlocked with the self_serve_onboarding
-- platform flag. Without the interlock an admin can point the CTA at live
-- Stripe checkout while onboarding is disabled, and the buyer pays and then
-- hits a dead wizard. The flag is the thing that decides whether their money
-- can turn into an organization, so it has to be on first.
create or replace function public.muster_admin_set_self_serve_paused(p_paused boolean)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_flag_on boolean;
begin
  if not muster.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_paused is null then raise exception 'paused must be true or false' using errcode = '22023'; end if;

  if p_paused = false then
    select coalesce(f.default_enabled, false) into v_flag_on
    from muster.feature_flags f where f.key = 'self_serve_onboarding';

    if not coalesce(v_flag_on, false) then
      raise exception 'enable the self_serve_onboarding feature flag before un-pausing self-serve checkout, or buyers will pay and then hit disabled onboarding'
        using errcode = '23514';
    end if;
  end if;

  update muster.pricing_settings set muster_self_serve_paused = p_paused, updated_at = now() where id = true;
  return public.muster_public_pricing();
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Grants.
--
-- Supabase default privileges GRANT EXECUTE on every new public-schema
-- function to anon AND authenticated. `revoke ... from public` does not undo
-- that, so anon is revoked by name. These three are admin writers: they must
-- never be reachable with the publishable key that ships in page source, even
-- though each also checks is_super_admin() internally.
-- muster_public_pricing stays anon-callable -- index.html is a logged-out page.
-- ---------------------------------------------------------------------------

revoke all on function public.muster_admin_set_pricing_visibility(text, boolean) from public, anon;
revoke all on function public.muster_admin_set_checkout_url(text, text) from public, anon;
revoke all on function public.muster_admin_set_self_serve_paused(boolean) from public, anon;

grant execute on function public.muster_admin_set_pricing_visibility(text, boolean) to authenticated, service_role;
grant execute on function public.muster_admin_set_checkout_url(text, text) to authenticated, service_role;
grant execute on function public.muster_admin_set_self_serve_paused(boolean) to authenticated, service_role;

grant execute on function public.muster_public_pricing() to anon, authenticated, service_role;
