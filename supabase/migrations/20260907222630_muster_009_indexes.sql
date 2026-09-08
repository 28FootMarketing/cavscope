-- Non-constraint indexes for the 29 generated tables, from pg_indexes.indexdef
-- on the live source. Constraint-backing indexes are excluded because
-- muster_006 already created them via the constraints themselves.
--
-- Several of these are partial and carry real semantics rather than being
-- performance-only:
--   brand_profiles_org_default_idx / _website_idx  one default brand per org,
--     one override per website, enforced as two partial uniques on the same table
--   incidents_fingerprint_active  a fingerprint may recur only once it is closed
--   pending_commercial_grants_email_unapplied  one unapplied grant per email,
--     case-insensitive -- this is what stops a double Stripe event provisioning twice
--   commercial_pricing_stripe_price_id_key  unique only where a price id is set
--
-- The two ivfflat indexes are the retrieval path. `lists = 100` is copied from
-- source rather than retuned; with 13 findings and 64 evidence rows the list
-- count is academic today, but changing it here would silently make this
-- project's recall differ from the one the contract tests were written against.

create index api_keys_agent_idx on muster.api_keys using btree (agent_id);
create unique index brand_profiles_org_default_idx on muster.brand_profiles using btree (organization_id) where (website_id is null);
create unique index brand_profiles_website_idx on muster.brand_profiles using btree (website_id) where (website_id is not null);
create index change_events_site_idx on muster.change_events using btree (website_id, detected_at desc);
create unique index commercial_pricing_stripe_price_id_key on muster.commercial_pricing using btree (stripe_price_id) where (stripe_price_id is not null);
create index idx_embedding_queue_unprocessed on muster.embedding_queue using btree (created_at) where (processed_at is null);
create index idx_evidence_embeddings_org on muster.evidence_embeddings using btree (organization_id);
create index idx_evidence_embeddings_vector on muster.evidence_embeddings using ivfflat (embedding vector_cosine_ops) with (lists='100');
create index idx_evidence_embeddings_website on muster.evidence_embeddings using btree (website_id);
create unique index feature_flag_overrides_org_idx on muster.feature_flag_overrides using btree (flag_key, organization_id) where (user_id is null);
create unique index feature_flag_overrides_user_idx on muster.feature_flag_overrides using btree (flag_key, user_id) where (user_id is not null);
create index idx_finding_embeddings_org on muster.finding_embeddings using btree (organization_id);
create index idx_finding_embeddings_vector on muster.finding_embeddings using ivfflat (embedding vector_cosine_ops) with (lists='100');
create index idx_finding_embeddings_website on muster.finding_embeddings using btree (website_id);
create index finding_evidence_scan_idx on muster.finding_evidence using btree (scan_id);
create index findings_org_idx on muster.findings using btree (organization_id);
create index findings_website_status_idx on muster.findings using btree (website_id, status);
create unique index incidents_fingerprint_active on muster.incidents using btree (fingerprint) where ((status)::text <> all ((array['closed'::character varying, 'wont_fix'::character varying])::text[]));
create index incidents_status on muster.incidents using btree (status) where ((status)::text <> all ((array['closed'::character varying, 'wont_fix'::character varying])::text[]));
create index jurisdiction_laws_code_idx on muster.jurisdiction_laws using btree (jurisdiction_code);
create unique index notification_outbox_dedupe_key on muster.notification_outbox using btree (entity_type, entity_id, category);
create index notification_outbox_pending on muster.notification_outbox using btree (status, created_at) where ((status)::text = 'pending'::text);
create unique index pending_commercial_grants_email_unapplied on muster.pending_commercial_grants using btree (lower((email)::text)) where (applied_at is null);
create index scan_evidence_scan_idx on muster.scan_evidence using btree (scan_id);
create index scan_evidence_website_idx on muster.scan_evidence using btree (website_id, captured_at desc);
create index scans_active_idx on muster.scans using btree (status) where ((status)::text = any ((array['queued'::character varying, 'running'::character varying])::text[]));
create index scans_website_created_idx on muster.scans using btree (website_id, created_at desc);
create index sitreps_website_idx on muster.sitreps using btree (website_id, generated_at desc);
