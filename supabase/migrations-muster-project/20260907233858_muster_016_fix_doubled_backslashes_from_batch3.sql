-- Corrects a transcription error introduced by muster_015, not a defect in the
-- source. Three literals in two functions arrived here with doubled
-- backslashes:
--
--   do_add_website        '\\.'  in the URL regex        -> should be '\.'
--   do_add_website        '\\1'  in regexp_replace       -> should be '\1'
--   q_compliance_posture  '\\"'  in the disclaimer text  -> should be '\"'
--
-- The regex one mattered: '\\.' requires a literal backslash in the URL, so
-- every valid address would have been rejected. mgtmqucaldkaxvxglguw has the
-- single-backslash form and is correct; only this project was affected.
--
-- The repair reads each definition back out of the catalog and collapses the
-- doubled backslashes, rather than restating the bodies. Retyping is what
-- caused this, so it is not the tool used to fix it. chr(92) spells the
-- backslash so no layer of escaping can double it again.
do $$
declare
  d text;
  bs text := chr(92);
begin
  for d in
    select pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'muster'
      and p.proname in ('do_add_website', 'q_compliance_posture')
  loop
    execute replace(d, bs || bs, bs);
  end loop;
end $$;
