-- Billing wiring pass, part 3: correction to part 1. The un-pause guard built its list of tiers
-- with a text[] || text concatenation; Postgres read the right-hand literal as an array literal
-- and failed ("malformed array literal") the first time a tier was actually missing. Found by
-- exercising the refusal in a rolled-back transaction before any page used it. It now uses
-- array_append, and the refusal names the tier: "CavScope Partner (seed)".

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
      v_missing := array_append(v_missing, 'CavScope (' || s.current_stage || ')');
    end if;
    if s.show_muster_partner and coalesce(case s.current_stage when 'seed' then s.partner_seed_checkout_url else s.partner_fruit_checkout_url end, '') = '' then
      v_missing := array_append(v_missing, 'CavScope Partner (' || s.current_stage || ')');
    end if;
    if coalesce(array_length(v_missing, 1), 0) > 0 then
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
