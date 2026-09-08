-- Second half of the recovered baseline: ledger version 20260902030006
-- (sentinel_rls) + 20260903095157 (role rename), emitted already named muster.
--
-- This is the half that phase-1 actually depends on: muster.touch_updated_at()
-- is referenced on line 7 of 20260904034922_muster_phase1_scan_engine.sql.

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'muster_app') then
    create role muster_app login noinherit nobypassrls;
  end if;
end $$;

grant usage on schema muster to muster_app;
grant select, insert, update, delete on all tables in schema muster to muster_app;
grant usage, select on all sequences in schema muster to muster_app;
alter default privileges in schema muster grant select, insert, update, delete on tables to muster_app;
alter default privileges in schema muster grant usage, select on sequences to muster_app;

-- Value guards. Zod validates at the API edge; these hold when rows are written
-- by SQL or MCP.
alter table muster.users add constraint users_role_check check (role in ('user','admin'));
alter table muster.organization_members add constraint organization_members_role_check check (role in ('executive','risk_owner','control_owner','contributor','viewer'));
alter table muster.websites add constraint websites_environment_check check (environment in ('production','staging','development'));
alter table muster.strategic_objectives add constraint strategic_objectives_status_check check (status in ('on_track','watch','at_risk','complete'));
alter table muster.risk_appetites add constraint risk_appetites_cadence_check check (review_cadence in ('monthly','quarterly','semi_annual','annual'));
alter table muster.risk_appetites add constraint risk_appetites_threshold_check check (high_threshold >= critical_threshold);
alter table muster.risks add constraint risks_category_check check (category in ('security','privacy','accessibility','availability','third_party','governance'));
alter table muster.risks add constraint risks_source_check check (source in ('manual_review','security_scan','privacy_assessment','accessibility_audit','vendor_assessment','incident','control_test','other'));
alter table muster.risks add constraint risks_severity_check check (severity in ('critical','high','medium','low'));
alter table muster.risks add constraint risks_status_check check (status in ('open','in_progress','accepted','mitigated','closed'));
alter table muster.risks add constraint risks_treatment_check check (treatment in ('mitigate','transfer','accept','avoid'));
alter table muster.risks add constraint risks_scores_check check (inherent_score between 0 and 25 and residual_score between 0 and 25);
alter table muster.controls add constraint controls_framework_check check (framework in ('SOC_2','ISO_27001','GDPR','PCI_DSS','WCAG','NIST_CSF','HIPAA','CUSTOM'));
alter table muster.controls add constraint controls_assessment_check check (assessment in ('not_assessed','not_met','partial','met','not_applicable'));
alter table muster.risk_control_mappings add constraint risk_control_relationship_check check (relationship in ('prevent','detect','govern'));
alter table muster.evidence add constraint evidence_type_check check (evidence_type in ('policy','scan','attestation','record','screenshot','ticket','other'));
alter table muster.evidence add constraint evidence_review_check check (review_state in ('pending','in_review','approved','expired','rejected'));
alter table muster.evidence_links add constraint evidence_links_target_check check (risk_id is not null or control_id is not null);
alter table muster.remediation_actions add constraint remediation_status_check check (status in ('not_started','in_progress','blocked','complete','verified'));
alter table muster.remediation_actions add constraint remediation_progress_check check (progress between 0 and 100);
alter table muster.remediation_actions add constraint remediation_escalation_check check (escalation_status in ('none','escalated','acknowledged','resolved'));
alter table muster.control_tests add constraint control_tests_status_check check (test_status in ('planned','in_progress','ready_for_review','approved','rework_required'));
alter table muster.control_tests add constraint control_tests_effectiveness_check check (operating_effectiveness in ('effective','partially_effective','ineffective','not_tested'));
alter table muster.control_tests add constraint control_tests_period_check check (period_end > period_start);
alter table muster.risk_exceptions add constraint risk_exceptions_type_check check (exception_type in ('temporary_acceptance','compensating_control','policy_deviation','business_override'));
alter table muster.risk_exceptions add constraint risk_exceptions_status_check check (status in ('requested','approved','expired','rejected','revoked'));
alter table muster.remediation_milestones add constraint milestones_status_check check (status in ('not_started','in_progress','blocked','complete','validated'));
alter table muster.remediation_milestones add constraint milestones_escalation_check check (escalation_status in ('none','escalated','acknowledged','resolved'));

-- RLS lockdown. The schema is not exposed to PostgREST; anon/authenticated hold
-- no grants. (Verified on the source project: an anon request with
-- Accept-Profile: muster returns PGRST106.)
do $$
declare t text;
begin
  for t in select tablename from pg_tables where schemaname = 'muster' loop
    execute format('alter table muster.%I enable row level security', t);
    execute format('drop policy if exists muster_app_all on muster.%I', t);
    execute format('create policy muster_app_all on muster.%I for all to muster_app using (true) with check (true)', t);
  end loop;
end $$;

revoke all on schema muster from anon, authenticated;
revoke all on all tables in schema muster from anon, authenticated;

-- Keeps updated_at honest for writes that bypass the app (MCP, psql).
-- This is the object phase-1 assumes already exists.
create or replace function muster.touch_updated_at() returns trigger
language plpgsql set search_path = muster, pg_temp as $$
begin
  new.updated_at = now();
  return new;
end $$;

do $$
declare t text;
begin
  for t in select tablename from pg_tables where schemaname = 'muster'
    and exists (select 1 from information_schema.columns c
                where c.table_schema = 'muster' and c.table_name = pg_tables.tablename
                  and c.column_name = 'updated_at') loop
    execute format('drop trigger if exists touch_updated_at on muster.%I', t);
    execute format('create trigger touch_updated_at before update on muster.%I for each row execute function muster.touch_updated_at()', t);
  end loop;
end $$;
