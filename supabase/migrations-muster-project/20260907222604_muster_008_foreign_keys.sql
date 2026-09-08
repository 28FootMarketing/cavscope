-- Foreign keys for the 29 generated tables, from pg_get_constraintdef on the
-- live source. Delete behaviour matters and is preserved exactly: cascade where
-- a child has no meaning without its parent (evidence under a scan), set null
-- where the reference is advisory (change_events.prev_scan_id,
-- user_preferences.default_organization_id), and plain restrict elsewhere so a
-- referenced org or user cannot be deleted out from under live rows.

alter table muster.agents add constraint agents_created_by_id_fkey foreign key (created_by_id) references muster.users(id);
alter table muster.agents add constraint agents_organization_id_fkey foreign key (organization_id) references muster.organizations(id) on delete cascade;
alter table muster.api_keys add constraint api_keys_agent_id_fkey foreign key (agent_id) references muster.agents(id) on delete cascade;
alter table muster.api_keys add constraint api_keys_created_by_id_fkey foreign key (created_by_id) references muster.users(id);
alter table muster.api_keys add constraint api_keys_organization_id_fkey foreign key (organization_id) references muster.organizations(id) on delete cascade;
alter table muster.brand_profiles add constraint brand_profiles_created_by_id_fkey foreign key (created_by_id) references muster.users(id);
alter table muster.brand_profiles add constraint brand_profiles_organization_id_fkey foreign key (organization_id) references muster.organizations(id) on delete cascade;
alter table muster.brand_profiles add constraint brand_profiles_website_id_fkey foreign key (website_id) references muster.websites(id) on delete cascade;
alter table muster.change_events add constraint change_events_prev_scan_id_fkey foreign key (prev_scan_id) references muster.scans(id) on delete set null;
alter table muster.change_events add constraint change_events_scan_id_fkey foreign key (scan_id) references muster.scans(id) on delete cascade;
alter table muster.change_events add constraint change_events_website_id_fkey foreign key (website_id) references muster.websites(id) on delete cascade;
alter table muster.commercial_pricing add constraint commercial_pricing_maps_to_plan_fkey foreign key (maps_to_plan) references muster.plans(plan);
alter table muster.evidence_embeddings add constraint evidence_embeddings_evidence_id_fkey foreign key (evidence_id) references muster.scan_evidence(id) on delete cascade;
alter table muster.feature_flag_overrides add constraint feature_flag_overrides_flag_key_fkey foreign key (flag_key) references muster.feature_flags(key) on delete cascade;
alter table muster.feature_flag_overrides add constraint feature_flag_overrides_organization_id_fkey foreign key (organization_id) references muster.organizations(id) on delete cascade;
alter table muster.feature_flag_overrides add constraint feature_flag_overrides_set_by_id_fkey foreign key (set_by_id) references muster.users(id);
alter table muster.feature_flag_overrides add constraint feature_flag_overrides_user_id_fkey foreign key (user_id) references muster.users(id) on delete cascade;
alter table muster.feature_flags add constraint feature_flags_plan_minimum_fkey foreign key (plan_minimum) references muster.plans(plan);
alter table muster.finding_embeddings add constraint finding_embeddings_finding_id_fkey foreign key (finding_id) references muster.findings(id) on delete cascade;
alter table muster.finding_evidence add constraint finding_evidence_evidence_id_fkey foreign key (evidence_id) references muster.scan_evidence(id) on delete cascade;
alter table muster.finding_evidence add constraint finding_evidence_finding_id_fkey foreign key (finding_id) references muster.findings(id) on delete cascade;
alter table muster.finding_evidence add constraint finding_evidence_scan_id_fkey foreign key (scan_id) references muster.scans(id) on delete cascade;
alter table muster.findings add constraint findings_first_seen_scan_id_fkey foreign key (first_seen_scan_id) references muster.scans(id);
alter table muster.findings add constraint findings_last_seen_scan_id_fkey foreign key (last_seen_scan_id) references muster.scans(id);
alter table muster.findings add constraint findings_organization_id_fkey foreign key (organization_id) references muster.organizations(id);
alter table muster.findings add constraint findings_resolved_by_scan_id_fkey foreign key (resolved_by_scan_id) references muster.scans(id);
alter table muster.findings add constraint findings_risk_id_fkey foreign key (risk_id) references muster.risks(id);
alter table muster.findings add constraint findings_rule_id_fkey foreign key (rule_id) references muster.scan_rules(rule_id);
alter table muster.findings add constraint findings_status_changed_by_id_fkey foreign key (status_changed_by_id) references muster.users(id);
alter table muster.findings add constraint findings_website_id_fkey foreign key (website_id) references muster.websites(id) on delete cascade;
alter table muster.jurisdiction_laws add constraint jurisdiction_laws_jurisdiction_code_fkey foreign key (jurisdiction_code) references muster.jurisdictions(code) on delete cascade;
alter table muster.jurisdictions add constraint jurisdictions_country_code_fkey foreign key (country_code) references muster.countries(code);
alter table muster.jurisdictions add constraint jurisdictions_parent_code_fkey foreign key (parent_code) references muster.jurisdictions(code);
alter table muster.notification_outbox add constraint notification_outbox_organization_id_fkey foreign key (organization_id) references muster.organizations(id);
alter table muster.onboarding_steps add constraint onboarding_steps_completed_by_id_fkey foreign key (completed_by_id) references muster.users(id);
alter table muster.onboarding_steps add constraint onboarding_steps_organization_id_fkey foreign key (organization_id) references muster.organizations(id) on delete cascade;
alter table muster.pending_commercial_grants add constraint pending_commercial_grants_plan_fkey foreign key (plan) references muster.plans(plan);
alter table muster.pending_invites add constraint pending_invites_invited_by_id_fkey foreign key (invited_by_id) references muster.users(id);
alter table muster.pending_invites add constraint pending_invites_organization_id_fkey foreign key (organization_id) references muster.organizations(id) on delete cascade;
alter table muster.scan_evidence add constraint scan_evidence_organization_id_fkey foreign key (organization_id) references muster.organizations(id);
alter table muster.scan_evidence add constraint scan_evidence_scan_id_fkey foreign key (scan_id) references muster.scans(id) on delete cascade;
alter table muster.scan_evidence add constraint scan_evidence_website_id_fkey foreign key (website_id) references muster.websites(id) on delete cascade;
alter table muster.scan_postprocess add constraint scan_postprocess_scan_id_fkey foreign key (scan_id) references muster.scans(id) on delete cascade;
alter table muster.scans add constraint scans_organization_id_fkey foreign key (organization_id) references muster.organizations(id);
alter table muster.scans add constraint scans_requested_by_agent_fk foreign key (requested_by_agent_id) references muster.agents(id);
alter table muster.scans add constraint scans_requested_by_id_fkey foreign key (requested_by_id) references muster.users(id);
alter table muster.scans add constraint scans_website_id_fkey foreign key (website_id) references muster.websites(id) on delete cascade;
alter table muster.sitreps add constraint sitreps_organization_id_fkey foreign key (organization_id) references muster.organizations(id);
alter table muster.sitreps add constraint sitreps_scan_id_fkey foreign key (scan_id) references muster.scans(id) on delete cascade;
alter table muster.sitreps add constraint sitreps_website_id_fkey foreign key (website_id) references muster.websites(id) on delete cascade;
alter table muster.user_preferences add constraint user_preferences_default_organization_id_fkey foreign key (default_organization_id) references muster.organizations(id) on delete set null;
alter table muster.user_preferences add constraint user_preferences_user_id_fkey foreign key (user_id) references muster.users(id) on delete cascade;
alter table muster.website_scan_settings add constraint website_scan_settings_website_id_fkey foreign key (website_id) references muster.websites(id) on delete cascade;
