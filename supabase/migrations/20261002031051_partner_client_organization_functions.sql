-- Functions for client organizations; see 20261002031035 for the design. Behaviour was proved in a
-- rolled-back transaction on 2026-10-02: create, duplicate name, bad industry, over allowance,
-- non-Partner, chain, list, non-admin allowance, contributor, stranger and anon were all refused or
-- allowed as intended.
create or replace function cavscope.do_create_client_org(
  p_partner bigint, p_name text, p_industry text, p_user_id bigint)
returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_partner   cavscope.organizations%rowtype;
  v_name      text := btrim(coalesce(p_name, ''));
  v_industry  text := nullif(btrim(coalesce(p_industry, '')), '');
  v_count     integer;
  v_client_id bigint;
begin
  select * into v_partner from cavscope.organizations where id = p_partner;
  if not found then raise exception 'organization not found' using errcode = 'P0002'; end if;
  if v_partner.partner_client_allowance is null then
    raise exception 'this organization is not on the Partner tier' using errcode = '42501';
  end if;
  if not cavscope.has_flag(p_partner, 'client_management_enabled') then
    raise exception 'client organization management is not enabled for this organization' using errcode = '42501';
  end if;
  if v_partner.managed_by_org_id is not null then
    raise exception 'a client organization cannot manage clients of its own' using errcode = '42501';
  end if;
  if char_length(v_name) < 2 or char_length(v_name) > 120 then
    raise exception 'client organization name must be 2 to 120 characters' using errcode = '22023';
  end if;
  if v_industry is not null and not exists (select 1 from cavscope.industries where key = v_industry) then
    raise exception 'industry must be one of the listed industries' using errcode = '22023';
  end if;
  -- Serialise creates per Partner so two clicks cannot both squeeze under the allowance.
  perform pg_advisory_xact_lock(hashtextextended('cavscope:client_org:' || p_partner::text, 0));
  select count(*) into v_count from cavscope.organizations where managed_by_org_id = p_partner;
  if v_count >= v_partner.partner_client_allowance then
    raise exception 'your Partner plan includes % client organizations and all are in use. Additional organizations are not available self-serve yet; contact CavScope to add more.',
      v_partner.partner_client_allowance using errcode = '42501';
  end if;
  if exists (select 1 from cavscope.organizations
             where managed_by_org_id = p_partner and lower(name) = lower(v_name)) then
    raise exception 'you already have a client organization with that name' using errcode = '23505';
  end if;

  insert into cavscope.organizations
    (name, industry, risk_owner_id, plan, country_code, region_code, timezone, website_limit,
     onboarding_status, onboarding_completed_at, created_by_id, managed_by_org_id, commercial_stage)
  values
    (v_name, left(v_industry, 120), p_user_id, v_partner.plan, v_partner.country_code, v_partner.region_code,
     v_partner.timezone, v_partner.website_limit, 'complete', now(), p_user_id, p_partner, v_partner.commercial_stage)
  returning id into v_client_id;

  insert into cavscope.organization_members (organization_id, user_id, role)
  values (v_client_id, p_user_id, 'executive');

  insert into cavscope.activity_events (organization_id, entity_type, entity_id, action, detail, actor_id)
  values (p_partner,  'organization', v_client_id, 'Client organization created', v_name, p_user_id),
         (v_client_id, 'organization', v_client_id, 'Created as a client of organization ' || p_partner, v_name, p_user_id);

  return jsonb_build_object('organization_id', v_client_id, 'name', v_name, 'managed_by_org_id', p_partner,
                            'used', v_count + 1, 'allowance', v_partner.partner_client_allowance);
end;
$function$;

create or replace function public.cavscope_create_client_org(
  p_partner_org_id bigint, p_name text, p_industry text default null)
returns jsonb language plpgsql security definer set search_path = '' as $function$
begin
  if coalesce(cavscope.org_role(p_partner_org_id), '') not in ('executive', 'super_admin') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return cavscope.do_create_client_org(p_partner_org_id, p_name, p_industry, cavscope.current_user_id());
end;
$function$;

create or replace function public.cavscope_client_orgs(p_partner_org_id bigint)
returns jsonb language plpgsql stable security definer set search_path = '' as $function$
declare v_allowance integer;
begin
  if cavscope.org_role(p_partner_org_id) is null then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select partner_client_allowance into v_allowance from cavscope.organizations where id = p_partner_org_id;
  return jsonb_build_object(
    'is_partner', v_allowance is not null,
    'allowance', v_allowance,
    'enabled', v_allowance is not null and cavscope.has_flag(p_partner_org_id, 'client_management_enabled'),
    'clients', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', c.id, 'name', c.name, 'industry', c.industry, 'created_at', c.created_at,
               'websites', (select count(*) from cavscope.websites w where w.organization_id = c.id))
             order by c.created_at)
      from cavscope.organizations c where c.managed_by_org_id = p_partner_org_id), '[]'::jsonb));
end;
$function$;

create or replace function public.cavscope_admin_set_partner_allowance(p_organization_id bigint, p_allowance integer)
returns jsonb language plpgsql security definer set search_path = '' as $function$
declare o cavscope.organizations; v_used integer;
begin
  if not cavscope.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_allowance is not null and p_allowance < 0 then
    raise exception 'allowance cannot be negative' using errcode = '22023';
  end if;
  select count(*) into v_used from cavscope.organizations where managed_by_org_id = p_organization_id;
  if p_allowance is not null and p_allowance < v_used then
    raise exception 'this Partner already has % client organizations; the allowance cannot go below that', v_used using errcode = '22023';
  end if;
  update cavscope.organizations set partner_client_allowance = p_allowance
   where id = p_organization_id returning * into o;
  if o.id is null then raise exception 'organization not found' using errcode = 'P0002'; end if;
  insert into cavscope.activity_events (organization_id, entity_type, entity_id, action, detail, actor_id)
  values (o.id, 'organization', o.id, 'Partner client allowance changed', coalesce(p_allowance::text, 'removed (not a Partner)'), cavscope.current_user_id());
  return jsonb_build_object('organization_id', o.id, 'allowance', o.partner_client_allowance, 'used', v_used);
end;
$function$;

-- Supabase hands every new public function to anon and authenticated by default.
revoke all on function public.cavscope_create_client_org(bigint, text, text) from public, anon;
revoke all on function public.cavscope_client_orgs(bigint) from public, anon;
revoke all on function public.cavscope_admin_set_partner_allowance(bigint, integer) from public, anon;
grant execute on function public.cavscope_create_client_org(bigint, text, text) to authenticated, service_role;
grant execute on function public.cavscope_client_orgs(bigint) to authenticated, service_role;
grant execute on function public.cavscope_admin_set_partner_allowance(bigint, integer) to authenticated, service_role;
revoke all on function cavscope.do_create_client_org(bigint, text, text, bigint) from public, anon, authenticated;

-- The flag is now read by SQL (the create path) and will be read by app.html's nav.
