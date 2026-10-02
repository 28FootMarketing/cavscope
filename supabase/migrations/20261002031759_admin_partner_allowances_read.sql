-- Console read: which organizations are Partners and how many linked clients each has used.
-- Super admin only, anon revoked by name. See 20261002031035 for the design.
create or replace function public.cavscope_admin_partner_allowances()
returns jsonb language plpgsql stable security definer set search_path = '' as $function$
begin
  if not cavscope.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'organization_id', o.id,
             'allowance', o.partner_client_allowance,
             'used', (select count(*) from cavscope.organizations c where c.managed_by_org_id = o.id),
             'managed_by_org_id', o.managed_by_org_id) order by o.id)
    from cavscope.organizations o), '[]'::jsonb);
end;
$function$;
revoke all on function public.cavscope_admin_partner_allowances() from public, anon;
grant execute on function public.cavscope_admin_partner_allowances() to authenticated, service_role;
