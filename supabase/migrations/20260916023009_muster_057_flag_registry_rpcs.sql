-- muster_054: the RPCs the Super Admin flag console reads and writes.
--
-- muster_admin_overview already returned `flags` and `overrides`, but as raw
-- table rows: no enforcement, no plan resolution, and overrides carrying bare
-- ids ("org #17") that nobody can act on. This adds one read RPC that answers
-- the questions a person actually has in front of a flag list -- does anything
-- read this, who has it overridden, what does each plan get -- plus the four
-- writes the console was missing entirely.
--
-- muster_admin_set_flag already accepted p_organization_id / p_user_id /
-- p_reason / p_expires_at; the console just never passed them. No new RPC is
-- needed to CREATE an override, only to clear one.

create or replace function public.muster_admin_flag_registry()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to ''
as $function$
declare v_flags jsonb; v_plans jsonb;
begin
  if not muster.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;

  select coalesce(jsonb_agg(jsonb_build_object('plan', p.plan, 'name', p.name, 'rank', p.rank) order by p.rank), '[]'::jsonb)
    into v_plans from muster.plans p;

  select coalesce(jsonb_agg(x order by x->>'category', x->>'key'), '[]'::jsonb) into v_flags
  from (
    select to_jsonb(f) || jsonb_build_object(
      'wired', coalesce(array_length(f.enforcement, 1), 0) > 0,
      -- What the flag resolves to for an org on each plan, ignoring overrides:
      -- kill switch first, then the plan gate, then the default.
      'enabled_by_plan', (
        select coalesce(jsonb_object_agg(p.plan,
          (not f.kill_switch)
          and f.default_enabled
          and (f.plan_minimum is null
               or p.rank >= (select rank from muster.plans mp where mp.plan = f.plan_minimum))), '{}'::jsonb)
        from muster.plans p),
      -- And what it resolves to right now, per org, overrides included.
      'orgs_enabled', (select count(*) from muster.organizations o where muster.flag_state_for_org(o.id, f.key)),
      'override_count', (select count(*) from muster.feature_flag_overrides fo
                         where fo.flag_key = f.key and (fo.expires_at is null or fo.expires_at > now())),
      'overrides', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', fo.id,
          'target_kind', case when fo.user_id is not null then 'user' else 'organization' end,
          'target_label', coalesce(tu.email, o.name, 'unknown'),
          'organization_id', fo.organization_id,
          'user_id', fo.user_id,
          'enabled', fo.enabled,
          'reason', fo.reason,
          'expires_at', fo.expires_at,
          'expired', fo.expires_at is not null and fo.expires_at <= now(),
          'set_by', su.email,
          'created_at', fo.created_at) order by fo.created_at desc), '[]'::jsonb)
        from muster.feature_flag_overrides fo
        left join muster.organizations o on o.id = fo.organization_id
        left join muster.users tu on tu.id = fo.user_id
        left join muster.users su on su.id = fo.set_by_id
        where fo.flag_key = f.key)
    ) as x
    from muster.feature_flags f
  ) s;

  return jsonb_build_object(
    'plans', v_plans,
    'flags', v_flags,
    'summary', jsonb_build_object(
      'total',         (select count(*) from muster.feature_flags),
      'wired',         (select count(*) from muster.feature_flags where coalesce(array_length(enforcement, 1), 0) > 0),
      'unwired',       (select count(*) from muster.feature_flags where coalesce(array_length(enforcement, 1), 0) = 0),
      'kill_switched', (select count(*) from muster.feature_flags where kill_switch),
      'overrides',     (select count(*) from muster.feature_flag_overrides where expires_at is null or expires_at > now()),
      'organizations', (select count(*) from muster.organizations)),
    'unwired_keys', (select coalesce(jsonb_agg(key order by key), '[]'::jsonb)
                     from muster.feature_flags where coalesce(array_length(enforcement, 1), 0) = 0));
end;
$function$;

comment on function public.muster_admin_flag_registry() is
  'Full feature flag inventory for the Super Admin console: every flag with where it is enforced, what it resolves to per plan and per org, and every override with its target resolved to a name. Super admin only.';

-- A new flag is unwired by definition -- nothing in the codebase reads a key
-- that did not exist a minute ago. This records that on the row rather than
-- letting the console imply otherwise, which is the exact failure muster_052
-- was written to fix.
create or replace function public.muster_admin_create_flag(
  p_key text, p_name text, p_description text,
  p_scope text DEFAULT 'organization', p_category text DEFAULT 'other',
  p_surface text DEFAULT NULL, p_default_enabled boolean DEFAULT false,
  p_plan_minimum text DEFAULT NULL)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare v_key text := lower(btrim(coalesce(p_key, '')));
begin
  if not muster.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  if v_key !~ '^[a-z][a-z0-9_]{2,47}$' then
    raise exception 'a flag key is lower_snake_case, 3 to 48 characters, starting with a letter' using errcode = '22023';
  end if;
  if exists (select 1 from muster.feature_flags where key = v_key) then
    raise exception 'flag % already exists', v_key using errcode = '23505';
  end if;
  if p_scope not in ('platform','organization','user') then
    raise exception 'scope must be platform, organization or user' using errcode = '22023';
  end if;
  if p_category not in ('workspace','reporting','partner','platform','engine','notifications','unbuilt','other') then
    raise exception 'unknown category %', p_category using errcode = '22023';
  end if;
  if p_plan_minimum is not null and not exists (select 1 from muster.plans where plan = p_plan_minimum) then
    raise exception 'no such plan %', p_plan_minimum using errcode = '22023';
  end if;
  if coalesce(btrim(p_description), '') = '' then
    raise exception 'a description is required -- it is what the next person reads before touching the switch' using errcode = '22023';
  end if;

  insert into muster.feature_flags (key, name, description, scope, default_enabled, plan_minimum,
                                    category, surface, enforcement, wiring_note)
  values (v_key, left(coalesce(nullif(btrim(p_name), ''), v_key), 96), btrim(p_description), p_scope,
          coalesce(p_default_enabled, false), p_plan_minimum, p_category, left(nullif(btrim(p_surface), ''), 96),
          '{}'::text[],
          'Created from the Super Admin console. Nothing reads this key yet -- add a muster.has_flag / muster.flag_state_for_org call at the surface it is meant to gate, then set enforcement on this row in a migration.');

  return (select to_jsonb(f) from muster.feature_flags f where f.key = v_key);
end;
$function$;

create or replace function public.muster_admin_clear_flag_override(p_id bigint)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare fo muster.feature_flag_overrides;
begin
  if not muster.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  delete from muster.feature_flag_overrides where id = p_id returning * into fo;
  if not found then raise exception 'no such override' using errcode = 'P0002'; end if;
  return to_jsonb(fo);
end;
$function$;

create or replace function public.muster_admin_set_flag_plan_minimum(p_key text, p_plan text DEFAULT NULL)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
begin
  if not muster.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  if not exists (select 1 from muster.feature_flags where key = p_key) then
    raise exception 'no such flag %', p_key using errcode = 'P0002';
  end if;
  if p_plan is not null and not exists (select 1 from muster.plans where plan = p_plan) then
    raise exception 'no such plan %', p_plan using errcode = '22023';
  end if;
  update muster.feature_flags set plan_minimum = p_plan where key = p_key;
  return (select to_jsonb(f) from muster.feature_flags f where f.key = p_key);
end;
$function$;

-- Deleting a flag that code still reads would make has_flag() return false for
-- it everywhere, silently switching that feature off for every tenant. Refuse,
-- and name the surfaces that would break.
create or replace function public.muster_admin_delete_flag(p_key text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare f muster.feature_flags%rowtype;
begin
  if not muster.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into f from muster.feature_flags where key = p_key;
  if not found then raise exception 'no such flag %', p_key using errcode = 'P0002'; end if;
  if coalesce(array_length(f.enforcement, 1), 0) > 0 then
    raise exception 'flag % is enforced in % and cannot be deleted -- has_flag would return false for it everywhere, switching that feature off for every tenant. Remove the code that reads it first.',
      p_key, array_to_string(f.enforcement, ', ') using errcode = '2BP01';
  end if;
  delete from muster.feature_flags where key = p_key;
  return to_jsonb(f);
end;
$function$;

-- Same grant shape as every other muster_admin_* RPC: reachable by a signed-in
-- session, refused inside the function unless the caller is a super admin, and
-- never reachable with the publishable key that ships in page source.
revoke all on function public.muster_admin_flag_registry() from public, anon;
revoke all on function public.muster_admin_create_flag(text, text, text, text, text, text, boolean, text) from public, anon;
revoke all on function public.muster_admin_clear_flag_override(bigint) from public, anon;
revoke all on function public.muster_admin_set_flag_plan_minimum(text, text) from public, anon;
revoke all on function public.muster_admin_delete_flag(text) from public, anon;

grant execute on function public.muster_admin_flag_registry() to authenticated, service_role;
grant execute on function public.muster_admin_create_flag(text, text, text, text, text, text, boolean, text) to authenticated, service_role;
grant execute on function public.muster_admin_clear_flag_override(bigint) to authenticated, service_role;
grant execute on function public.muster_admin_set_flag_plan_minimum(text, text) to authenticated, service_role;
grant execute on function public.muster_admin_delete_flag(text) to authenticated, service_role;
