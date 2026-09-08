-- Found by diffing this project's security advisors against the old project's,
-- not by reading code. Four divergences, every one of them making this project
-- MORE permissive than the project it was copied from:
--
--   public.rls_auto_enable()   old: postgres, authenticated, service_role
--                              new: PUBLIC, postgres, anon, authenticated, service_role
--   public.cron_error_log      old: RLS on + policy service_only
--                              new: RLS on + NO policy
--   public.cron_post_log ACL   old: postgres, service_role
--                              new: postgres, anon, authenticated, service_role
--
-- This is the third time the same root cause has bitten. muster_021 exists
-- because Postgres grants EXECUTE to PUBLIC on every new function, so a fresh
-- project starts more permissive than its source. muster_027 exists because the
-- shim migrations selected objects with `proname like 'muster%'` and six RPCs
-- did not carry the prefix. rls_auto_enable is both at once: it came from
-- muster_002_platform_cron_helpers, it is SECURITY DEFINER, and it is not named
-- muster*, so muster_021's lockdown never looked at it.
--
-- cron_error_log's missing policy is the inverse shape -- RLS on with no policy
-- is deny-all, so it is stricter, not looser. It is still drift, and the old
-- project's service_only policy is replicated here rather than left to the
-- question of whether service_role bypasses RLS on this instance.

-- 1. rls_auto_enable: match the source ACL exactly.
revoke execute on function public.rls_auto_enable() from public;
revoke execute on function public.rls_auto_enable() from anon;

-- 2. cron_error_log: the policy the source has and this project did not.
drop policy if exists service_only on public.cron_error_log;
create policy service_only on public.cron_error_log
  as permissive for all to public
  using ((select auth.role()) = 'service_role');

-- 3. cron_post_log: the source grants only postgres and service_role.
revoke all on table public.cron_post_log from anon;
revoke all on table public.cron_post_log from authenticated;

-- Verify against the source's actual state rather than trusting the statements above.
do $$
declare v_acl text; v_n int;
begin
  select array_to_string(p.proacl,' | ') into v_acl
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname='public' and p.proname='rls_auto_enable';
  if v_acl <> 'postgres=X/postgres | authenticated=X/postgres | service_role=X/postgres' then
    raise exception 'rls_auto_enable ACL is %, expected the source ACL', v_acl;
  end if;

  select count(*) into v_n from pg_policies
  where schemaname='public' and tablename='cron_error_log' and policyname='service_only';
  if v_n <> 1 then raise exception 'cron_error_log service_only policy missing'; end if;

  select array_to_string(c.relacl,' | ') into v_acl
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname='public' and c.relname='cron_post_log';
  if v_acl <> 'postgres=arwdDxtm/postgres | service_role=arwdDxtm/postgres' then
    raise exception 'cron_post_log ACL is %, expected the source ACL', v_acl;
  end if;
end $$;
