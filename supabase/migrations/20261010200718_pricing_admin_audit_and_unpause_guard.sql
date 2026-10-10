-- Billing wiring pass (admin.html), part 1.
--
-- The four public-pricing writers (stage, tier visibility, self-serve pause, checkout destination)
-- change what buyers see and where they pay, and recorded nothing: no who, no when, no before.
-- Each now writes cavscope.platform_audit ("seed -> fruit"; a no-op writes nothing). They also
-- called public.muster_public_pricing(); stage 5 drops that alias, which would have broken every
-- pricing write. They call cavscope_public_pricing() now.
-- cavscope_admin_set_self_serve_paused also refuses to un-pause while a tier the public page is
-- showing has no checkout link for the current stage. (As applied this migration built the list
-- with a text[] || text concatenation that failed on the first missing tier; part 3,
-- 20261010200812, corrects it. This file is kept as applied.)

create or replace function public.cavscope_admin_set_pricing_stage(p_stage text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare v_old text;
begin
  if not cavscope.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_stage not in ('seed', 'fruit') then raise exception 'stage must be seed or fruit' using errcode = '22023'; end if;
  select current_stage into v_old from cavscope.pricing_settings where id = true for update;
  update cavscope.pricing_settings set current_stage = p_stage, updated_at = now() where id = true;
  if v_old is distinct from p_stage then
    insert into cavscope.platform_audit (actor_id, action, target, detail)
    values (cavscope.current_user_id(), 'Pricing stage changed', 'public pricing', coalesce(v_old, 'unset') || ' -> ' || p_stage);
  end if;
  return public.cavscope_public_pricing();
end;
$function$;

create or replace function public.cavscope_admin_set_pricing_visibility(p_tier text, p_visible boolean)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  v_show_muster boolean;
  v_show_partner boolean;
  v_show_enterprise boolean;
  v_old boolean;
begin
  if not cavscope.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_tier not in ('muster', 'muster_partner', 'enterprise') then
    raise exception 'tier must be muster, muster_partner or enterprise' using errcode = '22023';
  end if;
  if p_visible is null then
    raise exception 'visible must be true or false' using errcode = '22023';
  end if;

  select
    case when p_tier = 'muster'         then p_visible else s.show_muster end,
    case when p_tier = 'muster_partner' then p_visible else s.show_muster_partner end,
    case when p_tier = 'enterprise'     then p_visible else s.show_enterprise end,
    case p_tier when 'muster' then s.show_muster when 'muster_partner' then s.show_muster_partner else s.show_enterprise end
  into v_show_muster, v_show_partner, v_show_enterprise, v_old
  from cavscope.pricing_settings s where s.id = true for update;

  if not (v_show_muster or v_show_partner or v_show_enterprise) then
    raise exception 'at least one pricing tier must stay visible' using errcode = '23514';
  end if;

  update cavscope.pricing_settings set
    show_muster = v_show_muster,
    show_muster_partner = v_show_partner,
    show_enterprise = v_show_enterprise,
    updated_at = now()
  where id = true;

  if v_old is distinct from p_visible then
    insert into cavscope.platform_audit (actor_id, action, target, detail)
    values (cavscope.current_user_id(), 'Pricing tier visibility changed', p_tier,
            case when p_visible then 'hidden -> shown' else 'shown -> hidden' end);
  end if;
  return public.cavscope_public_pricing();
end;
$function$;

create or replace function public.cavscope_admin_set_self_serve_paused(p_paused boolean)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  v_flag_on boolean;
  s cavscope.pricing_settings;
  v_missing text[] := '{}';
  v_old boolean;
begin
  if not cavscope.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_paused is null then raise exception 'paused must be true or false' using errcode = '22023'; end if;

  select * into s from cavscope.pricing_settings where id = true for update;
  v_old := s.muster_self_serve_paused;

  if p_paused = false then
    select coalesce(f.default_enabled, false) into v_flag_on
    from cavscope.feature_flags f where f.key = 'self_serve_onboarding';

    if not coalesce(v_flag_on, false) then
      raise exception 'enable the self_serve_onboarding feature flag before un-pausing self-serve checkout, or buyers will pay and then hit disabled onboarding'
        using errcode = '23514';
    end if;

    if s.show_muster and coalesce(case s.current_stage when 'seed' then s.muster_seed_checkout_url else s.muster_fruit_checkout_url end, '') = '' then
      v_missing := v_missing || 'CavScope (' || s.current_stage || ')';
    end if;
    if s.show_muster_partner and coalesce(case s.current_stage when 'seed' then s.partner_seed_checkout_url else s.partner_fruit_checkout_url end, '') = '' then
      v_missing := v_missing || 'CavScope Partner (' || s.current_stage || ')';
    end if;
    if array_length(v_missing, 1) > 0 then
      raise exception 'no checkout link is set for a tier the public page is showing: %. Set it under Billing first, or buyers would reach a button that goes nowhere',
        array_to_string(v_missing, ', ') using errcode = '23514';
    end if;
  end if;

  update cavscope.pricing_settings set muster_self_serve_paused = p_paused, updated_at = now() where id = true;
  if v_old is distinct from p_paused then
    insert into cavscope.platform_audit (actor_id, action, target, detail)
    values (cavscope.current_user_id(), 'Self-serve checkout changed', 'public pricing',
            case when p_paused then 'live -> paused' else 'paused -> live' end);
  end if;
  return public.cavscope_public_pricing();
end;
$function$;

create or replace function public.cavscope_admin_set_checkout_url(p_key text, p_url text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  v_url text;
  v_base_seed text;
  v_base_fruit text;
  v_old text;
begin
  if not cavscope.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_key not in (
    'muster_seed_checkout_url', 'muster_fruit_checkout_url', 'muster_contact_url',
    'partner_seed_checkout_url', 'partner_fruit_checkout_url', 'partner_intake_url',
    'partner_contact_url', 'enterprise_contact_url'
  ) then
    raise exception 'unknown CTA destination key: %', p_key using errcode = '22023';
  end if;

  v_url := nullif(btrim(coalesce(p_url, '')), '');

  if not cavscope.is_valid_cta_destination(v_url) then
    raise exception 'destination must be absolute https to a real host, or a mailto: address'
      using errcode = '22023';
  end if;

  if v_url is not null and p_key in ('partner_seed_checkout_url', 'partner_fruit_checkout_url') then
    select s.muster_seed_checkout_url, s.muster_fruit_checkout_url
      into v_base_seed, v_base_fruit
      from cavscope.pricing_settings s where s.id = true;

    if v_url in (coalesce(v_base_seed, ''), coalesce(v_base_fruit, '')) then
      raise exception 'that is a base-tier Payment Link (metadata tier=muster). CavScope Partner needs its own Stripe price and Payment Link carrying metadata tier=muster_partner, or the buyer is undercharged and provisioned the wrong plan'
        using errcode = '23514';
    end if;
  end if;

  select to_jsonb(s) ->> p_key into v_old from cavscope.pricing_settings s where s.id = true for update;

  update cavscope.pricing_settings set
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

  if v_old is distinct from v_url then
    insert into cavscope.platform_audit (actor_id, action, target, detail)
    values (cavscope.current_user_id(), 'Pricing destination changed', p_key,
            coalesce(v_old, 'none') || ' -> ' || coalesce(v_url, 'none'));
  end if;
  return public.cavscope_public_pricing();
end;
$function$;
