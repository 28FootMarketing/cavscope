-- Users & Roles wiring pass (admin.html).
--
-- 1. cavscope.platform_audit: a place for admin actions that belong to no single organization.
--    activity_events requires organization_id, so a platform role change had nowhere to be
--    recorded and cavscope_admin_set_user_role wrote nothing at all, for the one action that
--    grants access to every tenant's data. RLS on, no policies, no grants to anon or
--    authenticated: written only by SECURITY DEFINER admin functions, read only through
--    cavscope_admin_console().
-- 2. cavscope_admin_set_user_role records "super_admin -> user" (a no-op writes nothing) and
--    refuses to remove super_admin from the last super admin, in the database, because the
--    page's warning is not a guard.
-- 3. cavscope_admin_console() returns the ten most recent role changes as role_changes.
-- The console edit must apply exactly once or the migration aborts.

create table if not exists cavscope.platform_audit (
  id         bigint generated always as identity primary key,
  at         timestamptz not null default now(),
  actor_id   bigint references cavscope.users(id) on delete set null,
  action     text not null,
  target     text,
  detail     text
);
alter table cavscope.platform_audit enable row level security;
revoke all on cavscope.platform_audit from anon, authenticated, public;
comment on table cavscope.platform_audit is
  'Platform-level admin actions that belong to no single organization (activity_events requires one). Written only by SECURITY DEFINER admin functions; read only through cavscope_admin_console().';

create or replace function public.cavscope_admin_set_user_role(p_email text, p_role text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  u cavscope.users;
  v_old text;
  v_supers integer;
begin
  if not cavscope.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_role not in ('user','admin','super_admin') then raise exception 'invalid role' using errcode = '22023'; end if;

  select x.role into v_old from cavscope.users x where lower(x.email) = lower(p_email) for update;
  if not found then raise exception 'user not found' using errcode = 'P0002'; end if;

  -- Never leave the platform with nobody who can open the console. The page warns about
  -- removing your own access; this is the guard that does not depend on the page.
  if v_old = 'super_admin' and p_role <> 'super_admin' then
    select count(*) into v_supers from (
      select 1 from cavscope.users where role = 'super_admin' for update) s;
    if v_supers <= 1 then
      raise exception 'cannot remove super_admin from the last super admin' using errcode = '22023';
    end if;
  end if;

  update cavscope.users set role = p_role where lower(email) = lower(p_email) returning * into u;

  if v_old is distinct from p_role then
    insert into cavscope.platform_audit (actor_id, action, target, detail)
    values (cavscope.current_user_id(), 'Platform role changed', u.email, v_old || ' -> ' || p_role);
  end if;
  return to_jsonb(u);
end;
$function$;

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

  d := pg_temp.sub(d, '    ''websites'', (select coalesce(jsonb_agg(jsonb_build_object(',
    '    ''role_changes'', (select coalesce(jsonb_agg(jsonb_build_object(
          ''at'', a.at, ''target'', a.target, ''detail'', a.detail,
          ''actor'', (select ac.email from cavscope.users ac where ac.id = a.actor_id)) order by a.at desc), ''[]''::jsonb)
      from (select * from cavscope.platform_audit where action = ''Platform role changed'' order by at desc limit 10) a),

    ''websites'', (select coalesce(jsonb_agg(jsonb_build_object(');
  execute d;
end $mig$;
