-- Settings (feature-flag registry) wiring pass (admin.html).
--
-- 1. Every flag writer changes what some or every tenant can do, and none recorded who or when:
--    a default flip, a kill switch, a plan gate, an override set or revoked (setting one used to
--    remove the previous row first, so its reason was lost too), a flag created or removed. Each
--    now writes cavscope.platform_audit ("off -> on"; a no-op writes nothing).
-- 2. The page disables a switch whose flag is read by nothing, because a switch that changes nothing
--    reports a control that does not exist; the database did not enforce it, so a hand-made call
--    could. Setting a default, a plan gate or an override, or turning a kill switch ON, on a flag
--    nothing reads is now refused (22023). Turning a kill switch OFF stays allowed so an old one can
--    be cleared, and revoking an override stays allowed.
-- 3. cavscope_admin_set_flag (default path) and cavscope_admin_kill_switch updated zero rows for an
--    unknown key and returned null, which the page reported as saved. They now raise P0002.
-- 4. An override needs a reason of at least 8 characters in the database, as the page already asks.
-- 5. Setting an override replaces the existing row for that (flag, organization, user) in place.
-- create_flag, the override-revoke function and the flag-removal function are edited in place, and
-- each edit must apply exactly once or the migration aborts. (The removal and revoke edits anchor on
-- text that has no DELETE statement in it: the Supabase MCP connection hangs on a statement containing
-- one, which is also why override replacement is an UPDATE here.)

create or replace function pg_temp.sub(src text, old text, new text) returns text
language plpgsql as $f$
declare n int;
begin
  n := (length(src) - length(replace(src, old, ''))) / length(old);
  if n <> 1 then raise exception 'expected exactly 1 match, found % for: %', n, left(old, 80); end if;
  return replace(src, old, new);
end $f$;

create or replace function public.cavscope_admin_set_flag(p_key text, p_enabled boolean, p_organization_id bigint default null,
                                                         p_user_id bigint default null, p_reason text default null,
                                                         p_expires_at timestamp with time zone default null)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  f  cavscope.feature_flags;
  fo cavscope.feature_flag_overrides;
  v_old boolean;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if not cavscope.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;

  select * into f from cavscope.feature_flags where key = p_key for update;
  if not found then raise exception 'no such flag %', p_key using errcode = 'P0002'; end if;
  if coalesce(array_length(f.enforcement, 1), 0) = 0 then
    raise exception 'flag % is read by nothing, so this switch would change nothing', p_key using errcode = '22023';
  end if;

  if p_organization_id is null and p_user_id is null then
    v_old := f.default_enabled;
    update cavscope.feature_flags set default_enabled = p_enabled where key = p_key;
    if v_old is distinct from p_enabled then
      insert into cavscope.platform_audit (actor_id, action, target, detail)
      values (cavscope.current_user_id(), 'Feature flag default changed', p_key,
              case when p_enabled then 'off -> on' else 'on -> off' end);
    end if;
    return (select to_jsonb(x) from cavscope.feature_flags x where x.key = p_key);
  end if;

  if v_reason is null or length(v_reason) < 8 then
    raise exception 'an override needs a reason of at least 8 characters' using errcode = '22023';
  end if;

  -- One override per (flag, organization, user): replace it in place.
  update cavscope.feature_flag_overrides
     set enabled = p_enabled, reason = v_reason, set_by_id = cavscope.current_user_id(),
         expires_at = p_expires_at, created_at = now()
   where flag_key = p_key and organization_id is not distinct from p_organization_id and user_id is not distinct from p_user_id
   returning * into fo;
  if not found then
    insert into cavscope.feature_flag_overrides (flag_key, organization_id, user_id, enabled, reason, set_by_id, expires_at)
    values (p_key, p_organization_id, p_user_id, p_enabled, v_reason, cavscope.current_user_id(), p_expires_at)
    returning * into fo;
  end if;

  insert into cavscope.platform_audit (actor_id, action, target, detail)
  values (cavscope.current_user_id(), 'Feature flag override set', p_key,
          coalesce('organization ' || p_organization_id::text, 'user ' || p_user_id::text) || ' '
            || case when p_enabled then 'on' else 'off' end || ': ' || left(v_reason, 200));
  return to_jsonb(fo);
end;
$function$;

create or replace function public.cavscope_admin_set_flag_plan_minimum(p_key text, p_plan text default null)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare f cavscope.feature_flags;
begin
  if not cavscope.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into f from cavscope.feature_flags where key = p_key for update;
  if not found then raise exception 'no such flag %', p_key using errcode = 'P0002'; end if;
  if coalesce(array_length(f.enforcement, 1), 0) = 0 then
    raise exception 'flag % is read by nothing, so a plan gate on it would change nothing', p_key using errcode = '22023';
  end if;
  if p_plan is not null and not exists (select 1 from cavscope.plans where plan = p_plan) then
    raise exception 'no such plan %', p_plan using errcode = '22023';
  end if;
  update cavscope.feature_flags set plan_minimum = p_plan where key = p_key;
  if f.plan_minimum is distinct from p_plan then
    insert into cavscope.platform_audit (actor_id, action, target, detail)
    values (cavscope.current_user_id(), 'Feature flag plan gate changed', p_key,
            coalesce(f.plan_minimum, 'none') || ' -> ' || coalesce(p_plan, 'none'));
  end if;
  return (select to_jsonb(x) from cavscope.feature_flags x where x.key = p_key);
end;
$function$;

create or replace function public.cavscope_admin_kill_switch(p_key text, p_on boolean)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare f cavscope.feature_flags;
begin
  if not cavscope.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_on is null then raise exception 'on must be true or false' using errcode = '22023'; end if;
  select * into f from cavscope.feature_flags where key = p_key for update;
  if not found then raise exception 'no such flag %', p_key using errcode = 'P0002'; end if;
  if p_on and coalesce(array_length(f.enforcement, 1), 0) = 0 then
    raise exception 'flag % is read by nothing, so a kill switch on it would change nothing', p_key using errcode = '22023';
  end if;
  update cavscope.feature_flags set kill_switch = p_on where key = p_key;
  if f.kill_switch is distinct from p_on then
    insert into cavscope.platform_audit (actor_id, action, target, detail)
    values (cavscope.current_user_id(), 'Feature flag kill switch changed', p_key,
            case when p_on then 'off -> KILLED' else 'KILLED -> off' end);
  end if;
  return (select to_jsonb(x) from cavscope.feature_flags x where x.key = p_key);
end;
$function$;

do $mig$
declare d text;
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'cavscope_admin_create_flag';
  d := pg_temp.sub(d, '  return (select to_jsonb(f) from cavscope.feature_flags f where f.key = v_key);',
    '  insert into cavscope.platform_audit (actor_id, action, target, detail)
  values (cavscope.current_user_id(), ''Feature flag created'', v_key,
          ''default '' || case when coalesce(p_default_enabled, false) then ''on'' else ''off'' end || '', '' || p_scope || '', '' || p_category);

  return (select to_jsonb(f) from cavscope.feature_flags f where f.key = v_key);');
  execute d;

  -- Revoke and remove: edited in place so the statements that already work are not rewritten.
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'cavscope_admin_clear_flag_override';
  d := pg_temp.sub(d, '  if not found then raise exception ''no such override'' using errcode = ''P0002''; end if;',
    '  if not found then raise exception ''no such override'' using errcode = ''P0002''; end if;
  insert into cavscope.platform_audit (actor_id, action, target, detail)
  values (cavscope.current_user_id(), ''Feature flag override revoked'', fo.flag_key,
          coalesce(''organization '' || fo.organization_id::text, ''user '' || fo.user_id::text) || '' was ''
            || case when fo.enabled then ''on'' else ''off'' end || coalesce('': '' || left(fo.reason, 200), ''''));');
  execute d;

  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'cavscope_admin_delete_flag';
  d := pg_temp.sub(d, '  return to_jsonb(f);',
    '  insert into cavscope.platform_audit (actor_id, action, target, detail)
  values (cavscope.current_user_id(), ''Feature flag removed'', p_key, left(coalesce(f.description, ''''), 200));
  return to_jsonb(f);');
  execute d;
end $mig$;
