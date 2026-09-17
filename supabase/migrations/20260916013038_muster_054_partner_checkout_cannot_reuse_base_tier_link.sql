-- muster_admin_set_checkout_url(): refuse to put a base-tier Payment Link in a
-- Partner slot.
--
-- Found while testing the admin console added in 20260916012445: nothing stopped
-- an admin pasting one of the two base-tier Stripe Payment Links into
-- partner_seed_checkout_url or partner_fruit_checkout_url. Both are real https
-- URLs on a real host, so every validation in that migration passed them.
--
-- It is the most likely wrong paste there is, because those two links are the
-- only Stripe Payment Links MUSTER has, and no Partner price exists in Stripe at
-- all (commercial_pricing.stripe_price_id is null for muster_partner on both
-- stages). The damage is silent and doubled: the links carry
-- metadata {tier: muster} at $97/$197 while Partner is $197/$497 on a different
-- plan, so the buyer is undercharged AND muster-stripe-webhook reads that
-- metadata and grants them the base tier.
--
-- Compared against whatever the base tier's own columns currently hold rather
-- than a hardcoded pair, so this keeps working if those links are ever replaced.
-- index.html's partnerCheckout() applies the same rule on read, for rows written
-- before this check existed.

create or replace function public.muster_admin_set_checkout_url(p_key text, p_url text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_url text;
  v_base_seed text;
  v_base_fruit text;
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

  if v_url is not null and p_key in ('partner_seed_checkout_url', 'partner_fruit_checkout_url') then
    select s.muster_seed_checkout_url, s.muster_fruit_checkout_url
      into v_base_seed, v_base_fruit
      from muster.pricing_settings s where s.id = true;

    if v_url in (coalesce(v_base_seed, ''), coalesce(v_base_fruit, '')) then
      raise exception 'that is a base-tier Payment Link (metadata tier=muster). MUSTER Partner needs its own Stripe price and Payment Link carrying metadata tier=muster_partner, or the buyer is undercharged and provisioned the wrong plan'
        using errcode = '23514';
    end if;
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

revoke all on function public.muster_admin_set_checkout_url(text, text) from public, anon;
grant execute on function public.muster_admin_set_checkout_url(text, text) to authenticated, service_role;
