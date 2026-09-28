create or replace function public.muster_rule_status(p_rule_ids text[])
returns jsonb
language sql
stable
security definer
set search_path to ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'rule_id', r.rule_id, 'active', r.active, 'title', r.title,
           'default_severity', r.default_severity) order by r.rule_id), '[]'::jsonb)
    from muster.scan_rules r
   where r.rule_id = any(p_rule_ids);
$$;

revoke all on function public.muster_rule_status(text[]) from public;
revoke all on function public.muster_rule_status(text[]) from anon;
grant execute on function public.muster_rule_status(text[]) to authenticated, service_role;

do $$
declare
  v_acl text;
  v_n int;
begin
  select coalesce(array_to_string(p.proacl, ','), '') into v_acl
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'muster_rule_status';
  if v_acl like '%anon=%' then
    raise exception 'anon can still execute muster_rule_status: %', v_acl;
  end if;
  if v_acl not like '%authenticated=X%' then
    raise exception 'authenticated cannot execute muster_rule_status: %', v_acl;
  end if;
  select jsonb_array_length(public.muster_rule_status(array['GOV-001','GOV-006','NOPE-999'])) into v_n;
  if v_n <> 2 then
    raise exception 'expected 2 known rules back, got %', v_n;
  end if;
end $$;