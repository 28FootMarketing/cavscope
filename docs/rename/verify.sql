-- Run after 001_rpc_rename.sql (or inside its transaction for a dry run).
-- Every row must read ok = true.

select 'cavscope_ functions' as check, count(*) = 109 as ok, count(*) as got
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname like 'cavscope\_%'
union all
select 'legacy muster_ aliases (non-trigger)', count(*) = 109, count(*)
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname like 'muster\_%' and pg_get_function_result(p.oid) <> 'trigger'
union all
select 'aliases are SECURITY INVOKER', count(*) = 0, count(*)
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname like 'muster\_%' and pg_get_function_result(p.oid) <> 'trigger' and p.prosecdef
union all
select 'alias grants equal real function grants (grantee + privilege, ignoring grantor)', count(*) = 0, count(*)
from pg_proc m join pg_namespace mn on mn.oid = m.pronamespace
join pg_proc k on k.pronamespace = m.pronamespace and k.proname = 'cavscope_' || substr(m.proname, 8)
where mn.nspname = 'public' and m.proname like 'muster\_%' and pg_get_function_result(m.oid) <> 'trigger'
  and (select coalesce(array_agg(distinct (a.grantee, a.privilege_type) order by (a.grantee, a.privilege_type)), '{}') from aclexplode(coalesce(m.proacl, acldefault('f', m.proowner))) a where a.grantee <> m.proowner)
   is distinct from
      (select coalesce(array_agg(distinct (a.grantee, a.privilege_type) order by (a.grantee, a.privilege_type)), '{}') from aclexplode(coalesce(k.proacl, acldefault('f', k.proowner))) a where a.grantee <> k.proowner)
union all
select 'anon can still execute exactly the same set',
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like 'muster\_%' and has_function_privilege('anon', p.oid, 'execute'))
  = (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like 'cavscope\_%' and has_function_privilege('anon', p.oid, 'execute')),
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like 'cavscope\_%' and has_function_privilege('anon', p.oid, 'execute'));
