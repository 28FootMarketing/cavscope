-- PROPOSED, NOT APPLIED. Target: hjowfnzpomzxazmzywxw.
--
-- Renames every non-trigger public.muster_* function to public.cavscope_*, and
-- leaves a thin public.muster_* alias behind so existing callers (pages, edge
-- functions, integrations, cron) keep working until nothing uses the old name.
--
-- Read docs/RENAME-PLAN.md before applying. When it is applied, the file that
-- goes into supabase/migrations/ is named after the version apply_migration
-- assigns (see supabase/migrations/README.md), not after this file.
--
-- Facts this was written against (read from the live catalog, 2026-09-30):
--   109 renameable functions, 3 triggers (left alone), no overloads, every
--   argument named, no OUT/INOUT/VARIADIC, all SECURITY DEFINER, 4 set-returning,
--   no existing cavscope_* function in public.
--
-- Per function:
--   1. ALTER FUNCTION ... RENAME. Body, owner, ACL and comment travel with it.
--   2. A SQL alias under the old name. SECURITY INVOKER on purpose: it runs as
--      the caller, so the real function's own checks and grants are what decide;
--      the alias can never grant more than the function it wraps.
--   3. The alias gets exactly the real function's EXECUTE grants. Supabase's
--      default privileges hand every new public function to anon and
--      authenticated, and `revoke ... from public` does not undo that, so the
--      alias starts from nothing and copies (the muster_engine_* rule in
--      CLAUDE.md, applied to 109 functions at once).
--
-- All-or-nothing: one transaction, and any collision raises and rolls back.

do $mig$
declare
  r record;
  v_call text;
  v_body text;
  v_role text;
  n int := 0;
begin
  for r in
    select p.oid, p.proname, substr(p.proname, 8) as base, p.proargnames, p.proargmodes, p.provolatile, p.proacl, p.proowner,
           pg_get_function_result(p.oid) as res,
           pg_get_function_arguments(p.oid) as args,
           pg_get_function_identity_arguments(p.oid) as idargs
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.prokind = 'f' and p.proname like 'muster\_%'
      and pg_get_function_result(p.oid) <> 'trigger'
    order by p.proname
  loop
    if exists (select 1 from pg_proc q join pg_namespace qn on qn.oid = q.pronamespace
               where qn.nspname = 'public' and q.proname = 'cavscope_' || r.base) then
      raise exception 'cavscope_% already exists', r.base;
    end if;

    execute format('alter function public.%I(%s) rename to %I', r.proname, r.idargs, 'cavscope_' || r.base);

    -- INPUT arguments only. proargnames also lists the output columns of a
    -- RETURNS TABLE function, and passing those to the real function would be
    -- a call it does not accept (2 of the 4 set-returning functions are TABLEs).
    select coalesce(string_agg(format('%I => %I', a, a), ', ' order by ord), '')
      into v_call from unnest(r.proargnames, r.proargmodes) with ordinality as t(a, m, ord)
      where m is null or m in ('i', 'v');
    v_body := case when r.res ilike 'setof%' or r.res ilike 'table%'
                   then format('select * from public.%I(%s)', 'cavscope_' || r.base, v_call)
                   else format('select public.%I(%s)', 'cavscope_' || r.base, v_call) end;

    execute format(
      'create function public.%I(%s) returns %s language sql %s set search_path = '''' as %L',
      r.proname, r.args, r.res,
      case r.provolatile when 'i' then 'immutable' when 's' then 'stable' else 'volatile' end,
      v_body);

    execute format('revoke all on function public.%I(%s) from public, anon, authenticated, service_role', r.proname, r.idargs);
    for v_role in
      select ro.rolname
      from aclexplode(coalesce(r.proacl, acldefault('f', r.proowner))) a
      join pg_roles ro on ro.oid = a.grantee
      where a.privilege_type = 'EXECUTE' and ro.rolname <> 'postgres'
    loop
      execute format('grant execute on function public.%I(%s) to %I', r.proname, r.idargs, v_role);
    end loop;
    if exists (select 1 from aclexplode(coalesce(r.proacl, acldefault('f', r.proowner))) a
               where a.grantee = 0 and a.privilege_type = 'EXECUTE') then
      execute format('grant execute on function public.%I(%s) to public', r.proname, r.idargs);
    end if;
    n := n + 1;
  end loop;

  if n <> 109 then
    raise exception 'expected to rename 109 functions, renamed %', n;
  end if;
end
$mig$;

notify pgrst, 'reload schema';
