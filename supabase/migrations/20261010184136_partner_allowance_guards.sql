-- Partner allowance guards (admin.html, Client Access).
--
-- public.cavscope_admin_set_partner_allowance now refuses, in the database, the two cases the
-- page already disabled: giving an allowance to an organization that is itself a client of a
-- Partner, and to the internal sandbox. A guard that lives only in the page is not a guard.
-- It also records the allowance it moved from ("none -> 5", "5 -> 10") and writes no activity
-- row for a no-op; before, the row held only the new value.

create or replace function public.cavscope_admin_set_partner_allowance(p_organization_id bigint, p_allowance integer)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  o cavscope.organizations;
  v_used integer;
  v_old integer;
  v_managed bigint;
  v_sandbox boolean;
begin
  if not cavscope.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_allowance is not null and p_allowance < 0 then
    raise exception 'allowance cannot be negative' using errcode = '22023';
  end if;

  select org.partner_client_allowance, org.managed_by_org_id, org.is_admin_sandbox
    into v_old, v_managed, v_sandbox
  from cavscope.organizations org where org.id = p_organization_id for update;
  if not found then raise exception 'organization not found' using errcode = 'P0002'; end if;

  -- The page already disables these two cases; the database now refuses them too, because a
  -- guard that lives only in the page is not a guard.
  if p_allowance is not null and v_managed is not null then
    raise exception 'this organization is itself a client of a Partner, so it cannot be a Partner' using errcode = '22023';
  end if;
  if p_allowance is not null and v_sandbox then
    raise exception 'the internal sandbox is not a customer and cannot be a Partner' using errcode = '22023';
  end if;

  select count(*) into v_used from cavscope.organizations where managed_by_org_id = p_organization_id;
  if p_allowance is not null and p_allowance < v_used then
    raise exception 'this Partner already has % client organizations; the allowance cannot go below that', v_used using errcode = '22023';
  end if;

  update cavscope.organizations set partner_client_allowance = p_allowance
   where id = p_organization_id returning * into o;

  if v_old is distinct from p_allowance then
    insert into cavscope.activity_events (organization_id, entity_type, entity_id, action, detail, actor_id)
    values (o.id, 'organization', o.id, 'Partner client allowance changed',
            coalesce(v_old::text, 'none') || ' -> ' || coalesce(p_allowance::text, 'removed (not a Partner)'),
            cavscope.current_user_id());
  end if;
  return jsonb_build_object('organization_id', o.id, 'allowance', o.partner_client_allowance, 'used', v_used);
end;
$function$;
