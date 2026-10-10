-- Console Organizations wiring pass (admin.html, Organizations section).
--
-- 1. The roster payload gains website_limit, managed_by_org_id / managed_by, client_orgs and a
--    top-level plan_limits map, so the page can show a client organization's Partner, each
--    tenant's site limit, and warn before a downgrade puts a tenant over its new limit.
-- 2. public.cavscope_admin_set_plan records the plan it moved from ("pro -> starter", where it
--    used to record only the new plan), refuses an unknown plan with 22023 instead of a raw
--    constraint error, and writes no activity row for a no-op.
-- Each in-place edit of the console function must apply exactly once or the migration aborts.

create or replace function pg_temp.sub(src text, old text, new text) returns text
language plpgsql as $f$
declare n int;
begin
  n := (length(src) - length(replace(src, old, ''))) / length(old);
  if n <> 1 then raise exception 'expected exactly 1 match, found % for: %', n, left(old, 80); end if;
  return replace(src, old, new);
end $f$;

do $mig$
declare d text;
begin
  select pg_get_functiondef(p.oid) into d
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'cavscope_admin_console';

  d := pg_temp.sub(d, '''onboarding_status'', o.onboarding_status, ''created_at'', o.created_at,',
    '''onboarding_status'', o.onboarding_status, ''created_at'', o.created_at,
          ''website_limit'', o.website_limit,
          ''managed_by_org_id'', o.managed_by_org_id,
          ''managed_by'', (select m.name from cavscope.organizations m where m.id = o.managed_by_org_id),
          ''client_orgs'', (select count(*) from cavscope.organizations c where c.managed_by_org_id = o.id),');
  d := pg_temp.sub(d, '''pricing'', public.cavscope_public_pricing());',
    '''plan_limits'', (select coalesce(jsonb_object_agg(pl.plan, pl.website_limit), ''{}''::jsonb) from cavscope.plans pl),
    ''pricing'', public.cavscope_public_pricing());');
  execute d;
end $mig$;

create or replace function public.cavscope_admin_set_plan(p_organization_id bigint, p_plan text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  o cavscope.organizations;
  v_old text;
  v_limit integer;
begin
  if not cavscope.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;

  select pl.website_limit into v_limit from cavscope.plans pl where pl.plan = p_plan;
  if not found then
    raise exception 'unknown plan: %', p_plan using errcode = '22023';
  end if;

  select org.plan into v_old from cavscope.organizations org where org.id = p_organization_id for update;
  if not found then raise exception 'organization not found' using errcode = 'P0002'; end if;

  update cavscope.organizations set plan = p_plan, website_limit = v_limit
  where id = p_organization_id returning * into o;

  if v_old is distinct from p_plan then
    insert into cavscope.activity_events (organization_id, entity_type, entity_id, action, detail, actor_id)
    values (o.id, 'organization', o.id, 'Plan changed', v_old || ' -> ' || p_plan, cavscope.current_user_id());
  end if;
  return to_jsonb(o);
end;
$function$;
