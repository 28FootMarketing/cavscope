-- RETROACTIVE RECORD. This was applied live to the shared project on
-- 2026-09-06 (deployed migration version 20260906005205) with no matching
-- file committed to the repo at the time -- discovered as repo/database
-- drift during the autonomy audit (.planning/autonomy/EVIDENCE-REGISTER.md
-- FIND-003). Written now, guarded to be a no-op if the live database
-- already has it (which it does), so the repo reproduces the live schema
-- from empty without erroring on a database that's already current.
--
-- Adds an 'ai_governance' category value to the two check constraints that
-- classify jurisdiction laws and scan rules.

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'muster.jurisdiction_laws'::regclass
      and conname = 'jurisdiction_laws_category_check'
      and pg_get_constraintdef(oid) like '%ai_governance%'
  ) then
    alter table muster.jurisdiction_laws drop constraint jurisdiction_laws_category_check;
    alter table muster.jurisdiction_laws add constraint jurisdiction_laws_category_check
      check ((category)::text = any (array['privacy','accessibility','security','marketing','breach','consumer','sector','ai_governance']::text[]));
  end if;
end $$;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'muster.scan_rules'::regclass
      and conname = 'scan_rules_category_check'
      and pg_get_constraintdef(oid) like '%ai_governance%'
  ) then
    alter table muster.scan_rules drop constraint scan_rules_category_check;
    alter table muster.scan_rules add constraint scan_rules_category_check
      check ((category)::text = any (array['security','privacy','accessibility','availability','third_party','governance','ai_governance']::text[]));
  end if;
end $$;
