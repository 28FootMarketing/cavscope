-- Primary keys and unique constraints for the 29 tables generated in
-- muster_005. Emitted from pg_get_constraintdef on the live source, so these
-- are the constraints actually in force -- not the repo's version of them.
-- The 16 baseline tables already carry theirs from muster_003/004.

alter table muster.agents add constraint agents_pkey primary key (id);
alter table muster.api_keys add constraint api_keys_pkey primary key (id);
alter table muster.brand_profiles add constraint brand_profiles_pkey primary key (id);
alter table muster.change_events add constraint change_events_pkey primary key (id);
alter table muster.commercial_pricing add constraint commercial_pricing_pkey primary key (tier, stage);
alter table muster.countries add constraint countries_pkey primary key (code);
alter table muster.embedding_queue add constraint embedding_queue_pkey primary key (id);
alter table muster.evidence_embeddings add constraint evidence_embeddings_pkey primary key (id);
alter table muster.feature_flag_overrides add constraint feature_flag_overrides_pkey primary key (id);
alter table muster.feature_flags add constraint feature_flags_pkey primary key (key);
alter table muster.finding_embeddings add constraint finding_embeddings_pkey primary key (id);
alter table muster.finding_evidence add constraint finding_evidence_pkey primary key (finding_id, evidence_id);
alter table muster.findings add constraint findings_pkey primary key (id);
alter table muster.incidents add constraint incidents_pkey primary key (id);
alter table muster.jurisdiction_laws add constraint jurisdiction_laws_pkey primary key (id);
alter table muster.jurisdictions add constraint jurisdictions_pkey primary key (code);
alter table muster.notification_outbox add constraint notification_outbox_pkey primary key (id);
alter table muster.onboarding_steps add constraint onboarding_steps_pkey primary key (id);
alter table muster.pending_commercial_grants add constraint pending_commercial_grants_pkey primary key (id);
alter table muster.pending_invites add constraint pending_invites_pkey primary key (id);
alter table muster.plans add constraint plans_pkey primary key (plan);
alter table muster.pricing_settings add constraint pricing_settings_pkey primary key (id);
alter table muster.scan_evidence add constraint scan_evidence_pkey primary key (id);
alter table muster.scan_postprocess add constraint scan_postprocess_pkey primary key (scan_id);
alter table muster.scan_rules add constraint scan_rules_pkey primary key (rule_id);
alter table muster.scans add constraint scans_pkey primary key (id);
alter table muster.sitreps add constraint sitreps_pkey primary key (id);
alter table muster.user_preferences add constraint user_preferences_pkey primary key (user_id);
alter table muster.website_scan_settings add constraint website_scan_settings_pkey primary key (website_id);

alter table muster.api_keys add constraint api_keys_key_hash_key unique (key_hash);
alter table muster.embedding_queue add constraint embedding_queue_entity_type_entity_id_key unique (entity_type, entity_id);
alter table muster.evidence_embeddings add constraint evidence_embeddings_evidence_id_chunk_index_key unique (evidence_id, chunk_index);
alter table muster.finding_embeddings add constraint finding_embeddings_finding_id_chunk_index_key unique (finding_id, chunk_index);
alter table muster.findings add constraint findings_website_id_fingerprint_key unique (website_id, fingerprint);
alter table muster.jurisdiction_laws add constraint jurisdiction_laws_jurisdiction_code_short_name_key unique (jurisdiction_code, short_name);
alter table muster.onboarding_steps add constraint onboarding_steps_organization_id_step_key_key unique (organization_id, step_key);
alter table muster.onboarding_steps add constraint onboarding_steps_organization_id_step_no_key unique (organization_id, step_no);
alter table muster.pending_invites add constraint pending_invites_organization_id_email_key unique (organization_id, email);
alter table muster.plans add constraint plans_rank_key unique (rank);
alter table muster.sitreps add constraint sitreps_scan_id_version_key unique (scan_id, version);
