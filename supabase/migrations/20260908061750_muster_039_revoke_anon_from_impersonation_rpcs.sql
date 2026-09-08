-- muster_039: take EXECUTE on the impersonation RPCs away from anon.
--
-- muster_038 said, in its own grant comment, that anon "should not be able to
-- call these at all". That was not what it achieved. It ran:
--
--   revoke all on function ... from public;
--   grant execute on function ... to authenticated, service_role;
--
-- which is the pattern the rest of muster_engine_* uses, and it is not enough
-- here. Supabase installs ALTER DEFAULT PRIVILEGES granting EXECUTE on new
-- functions in `public` to anon and authenticated as NAMED ROLES. Revoking from
-- PUBLIC removes the pseudo-role grant and leaves the named one untouched, so
-- all five functions ended up with anon=X while every pre-existing
-- muster_admin_* function has only postgres, authenticated and service_role.
--
-- Not a live hole: each function calls muster.is_super_admin() first, which is
-- false without an auth.uid(), and an anonymous call was verified to raise
-- 42501 before this migration. This is the defence-in-depth layer that was
-- claimed but not delivered, and it brings the five in line with their
-- neighbours.
--
-- The rule worth remembering: to strip anon from a function in `public` on
-- Supabase, revoke from anon by name. Revoking from public does not do it.

revoke execute on function public.muster_admin_impersonate_start(bigint, text, integer) from anon;
revoke execute on function public.muster_admin_impersonate_end() from anon;
revoke execute on function public.muster_admin_impersonate_status() from anon;
revoke execute on function public.muster_admin_impersonated_view() from anon;
revoke execute on function public.muster_admin_impersonation_log(integer) from anon;

do $$
declare r record;
begin
  for r in
    select p.proname, coalesce(p.proacl::text, '') as acl
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname like 'muster_admin_impersonat%'
  loop
    if r.acl like '%anon=%' then
      raise exception 'anon still holds EXECUTE on %: %', r.proname, r.acl;
    end if;
    if r.acl not like '%authenticated=X%' then
      raise exception 'authenticated lost EXECUTE on %: %', r.proname, r.acl;
    end if;
    if r.acl not like '%service_role=X%' then
      raise exception 'service_role lost EXECUTE on %: %', r.proname, r.acl;
    end if;
  end loop;
end $$;