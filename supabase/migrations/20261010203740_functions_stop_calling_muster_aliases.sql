-- Cross-section check (2026-10-10): six functions still called a public.muster_* alias. Stage 5 of
-- docs/RENAME-PLAN.md drops the aliases, which would have broken them (the admin Overview's incident
-- list among them). Each now calls the cavscope_ function the alias forwards to. Every target is
-- checked to exist, and an edit that finds nothing to replace aborts the migration.
-- After this no function in public or cavscope outside the aliases themselves references a muster_ name.

do $mig$
declare
  r record;
  d text;
  n int;
begin
  for r in select * from (values
      ('cavscope',  'test_retrieval_contract',                 'public.muster_engine_search_findings', 'public.cavscope_engine_search_findings'),
      ('public',    'cavscope_admin_overview',                 'public.muster_public_pricing',         'public.cavscope_public_pricing'),
      ('public',    'cavscope_engine_llm_config_for_website',  'public.muster_engine_llm_config',      'public.cavscope_engine_llm_config'),
      ('public',    'cavscope_invite',                         'public.muster_invite_member',          'public.cavscope_invite_member'),
      ('public',    'cavscope_onboarding_complete_step',       'public.muster_onboarding_state',       'public.cavscope_onboarding_state'),
      ('public',    'cavscope_set_llm_config',                 'public.muster_llm_config',             'public.cavscope_llm_config')
    ) v(sch, fn, old_ref, new_ref)
  loop
    if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                    where n.nspname = 'public' and p.proname = split_part(r.new_ref, '.', 2)) then
      raise exception 'target % does not exist', r.new_ref;
    end if;
    select pg_get_functiondef(p.oid) into d
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = r.sch and p.proname = r.fn;
    n := (length(d) - length(replace(d, r.old_ref, ''))) / length(r.old_ref);
    if n < 1 then raise exception 'nothing to replace in %.% for %', r.sch, r.fn, r.old_ref; end if;
    execute replace(d, r.old_ref, r.new_ref);
  end loop;
end $mig$;
