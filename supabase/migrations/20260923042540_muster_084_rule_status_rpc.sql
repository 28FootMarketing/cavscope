-- MUSTER 084: public.muster_rule_status(text[]) -- which rules a scan could have raised.
--
-- WHY
--
-- The workspace's AIO view scores a check as passed when its rule has no open
-- finding. That is only true if the rule was evaluated. A rule held inactive
-- (muster_063: ingest drops its findings) or a scan from an engine older than
-- the rule has no findings by construction, and scoring that as a pass is the
-- absence-of-findings-as-a-pass defect this project has refused everywhere else.
--
-- The page could see the scan's engine_version but not whether a rule was
-- active: scan_rules is in the muster schema, which PostgREST does not expose.
-- This returns exactly that and nothing more. It is reference data -- the same
-- rule catalog for every tenant, holding no tenant's data -- so it needs no org
-- check, but it is still granted to signed-in users only.
--
-- Grants: authenticated only. anon revoked BY NAME, because Supabase's default
-- privileges grant EXECUTE on every new public function to anon and
-- authenticated, and "revoke ... from public" does not undo that.

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
