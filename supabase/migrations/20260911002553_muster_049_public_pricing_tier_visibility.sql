-- muster_049: per-tier public pricing visibility toggles.
--
-- Seed/Fruit already controls which price each tier shows. This adds which
-- tiers index.html shows at all. The public page previously always rendered
-- MUSTER, MUSTER Partner, and MUSTER Enterprise even while base self-serve was
-- paused and only Partner was meant to be commercially active.
--
-- Defaults match that commercial decision: Partner on, MUSTER and Enterprise
-- off. A super-admin can flip any of them from the Public Pricing panel without
-- a redeploy. Enterprise is not a commercial_pricing row (custom quote) but it
-- is still a card on the marketing page, so it gets the same visibility switch.
--
-- Filename timestamp is provisional -- rename to the version apply_migration
-- assigns once this lands on hjowfnzpomzxazmzywxw (see migrations/README.md).

alter table muster.pricing_settings
  add column if not exists show_muster boolean not null default false,
  add column if not exists show_muster_partner boolean not null default true,
  add column if not exists show_enterprise boolean not null default false;

-- Existing singleton row predates these columns; pin the intentional defaults
-- rather than trusting whatever Postgres filled in for NOT NULL DEFAULT on add.
update muster.pricing_settings
set show_muster = false,
    show_muster_partner = true,
    show_enterprise = false,
    updated_at = now()
where id = true;

create or replace function public.muster_public_pricing()
returns jsonb
language sql
stable
security definer
set search_path to ''
as $function$
  select jsonb_build_object(
    'current_stage', s.current_stage,
    'visible', jsonb_build_object(
      'muster', s.show_muster,
      'muster_partner', s.show_muster_partner,
      'enterprise', s.show_enterprise
    ),
    'muster', (select jsonb_build_object('monthly_price_cents', p.monthly_price_cents)
      from muster.commercial_pricing p where p.tier = 'muster' and p.stage = s.current_stage),
    'muster_partner', (select jsonb_build_object('monthly_price_cents', p.monthly_price_cents,
        'included_client_orgs', p.included_client_orgs, 'additional_org_price_cents', p.additional_org_price_cents)
      from muster.commercial_pricing p where p.tier = 'muster_partner' and p.stage = s.current_stage)
  )
  from muster.pricing_settings s where s.id = true;
$function$;

revoke all on function public.muster_public_pricing() from public;
grant execute on function public.muster_public_pricing() to anon, authenticated;

create or replace function public.muster_admin_set_pricing_visibility(
  p_tier text,
  p_visible boolean
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if not muster.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_tier not in ('muster', 'muster_partner', 'enterprise') then
    raise exception 'tier must be muster, muster_partner, or enterprise' using errcode = '22023';
  end if;
  if p_visible is null then
    raise exception 'visible must be true or false' using errcode = '22023';
  end if;

  update muster.pricing_settings set
    show_muster = case when p_tier = 'muster' then p_visible else show_muster end,
    show_muster_partner = case when p_tier = 'muster_partner' then p_visible else show_muster_partner end,
    show_enterprise = case when p_tier = 'enterprise' then p_visible else show_enterprise end,
    updated_at = now()
  where id = true;

  return public.muster_public_pricing();
end;
$function$;

revoke all on function public.muster_admin_set_pricing_visibility(text, boolean) from public, anon;
grant execute on function public.muster_admin_set_pricing_visibility(text, boolean) to authenticated;
