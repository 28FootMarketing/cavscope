-- Function EXECUTE grants, matched to source. This is the security half of the
-- RPC layer and it does NOT come along for free: Postgres grants EXECUTE to
-- PUBLIC on every newly created function, so until this runs, all 70 shims and
-- all 58 muster.* functions are callable by anon on this project -- including
-- the engine internals, the vault secret readers, and the retrieval wrappers.
--
-- 50 functions are locked to service_role on mgtmqucaldkaxvxglguw. The same 50
-- are locked here. The five deliberately anon-reachable shims (muster_countries,
-- muster_jurisdiction_advisory, muster_plans, muster_public_pricing,
-- muster_regions) are left open, as on source -- the marketing site calls them
-- without a session.
revoke all on function muster.agent_tools() from public, anon, authenticated;
revoke all on function muster.autotriage() from public, anon, authenticated;
revoke all on function muster.do_add_website(p_org bigint, p_name text, p_url text, p_environment text, p_cadence_minutes integer, p_user_id bigint, p_trigger text) from public, anon, authenticated;
revoke all on function muster.do_onboard(p jsonb, p_user_id bigint) from public, anon, authenticated;
revoke all on function muster.do_promote_finding(p_finding_id bigint, p_user_id bigint, p_agent_id bigint) from public, anon, authenticated;
revoke all on function muster.do_request_scan(p_website_id bigint, p_user_id bigint, p_agent_id bigint, p_trigger text) from public, anon, authenticated;
revoke all on function muster.do_update_finding_status(p_finding_id bigint, p_status text, p_note text, p_user_id bigint, p_agent_id bigint) from public, anon, authenticated;
revoke all on function muster.drift_detect(p_scan_id bigint) from public, anon, authenticated;
revoke all on function muster.engine_claim(p_scan_id bigint, p_limit integer) from public, anon, authenticated;
revoke all on function muster.engine_fail(p_scan_id bigint, p_error text) from public, anon, authenticated;
revoke all on function muster.engine_ingest(p_scan_id bigint, p_scan jsonb, p_evidence jsonb, p_findings jsonb) from public, anon, authenticated;
revoke all on function muster.ensure_user_from_auth() from public, anon, authenticated;
revoke all on function muster.generate_sitrep(p_scan_id bigint) from public, anon, authenticated;
revoke all on function muster.mark_website_verified(p_website_id bigint) from public, anon, authenticated;
revoke all on function muster.q_brand(p_org bigint, p_website_id bigint) from public, anon, authenticated;
revoke all on function muster.q_compliance_posture(p_website_id bigint) from public, anon, authenticated;
revoke all on function muster.q_evidence(p_evidence_id bigint) from public, anon, authenticated;
revoke all on function muster.q_findings(p_website_id bigint, p_statuses text[]) from public, anon, authenticated;
revoke all on function muster.q_flags(p_org bigint) from public, anon, authenticated;
revoke all on function muster.q_jurisdiction_advisory(p_country text, p_region text, p_full boolean) from public, anon, authenticated;
revoke all on function muster.q_latest_sitrep(p_website_id bigint) from public, anon, authenticated;
revoke all on function muster.q_organization(p_org bigint) from public, anon, authenticated;
revoke all on function muster.q_scans(p_website_id bigint, p_limit integer) from public, anon, authenticated;
revoke all on function muster.q_search_evidence(p_website_id bigint, p_query_embedding vector, p_limit integer, p_threshold double precision) from public, anon, authenticated;
revoke all on function muster.q_search_findings(p_website_id bigint, p_query_embedding vector, p_limit integer, p_threshold double precision) from public, anon, authenticated;
revoke all on function muster.q_sitrep(p_sitrep_id bigint) from public, anon, authenticated;
revoke all on function muster.q_website_overview(p_website_id bigint) from public, anon, authenticated;
revoke all on function muster.q_website_summary(p_website_id bigint) from public, anon, authenticated;
revoke all on function muster.test_retrieval_contract() from public, anon, authenticated;
revoke all on function muster.touch_updated_at() from public, anon, authenticated;
revoke all on function public.muster_engine_agent_call(p_ctx jsonb, p_tool text, p_args jsonb) from public, anon, authenticated;
revoke all on function public.muster_engine_agent_tools() from public, anon, authenticated;
revoke all on function public.muster_engine_claim(p_scan_id bigint, p_limit integer) from public, anon, authenticated;
revoke all on function public.muster_engine_claim_alerts(p_limit integer) from public, anon, authenticated;
revoke all on function public.muster_engine_cron_health_check() from public, anon, authenticated;
revoke all on function public.muster_engine_fail(p_scan_id bigint, p_error text) from public, anon, authenticated;
revoke all on function public.muster_engine_ingest(p_scan_id bigint, p_scan jsonb, p_evidence jsonb, p_findings jsonb) from public, anon, authenticated;
revoke all on function public.muster_engine_record_commercial_grant(p_email text, p_tier text, p_stage text, p_stripe_customer_id text, p_stripe_subscription_id text) from public, anon, authenticated;
revoke all on function public.muster_engine_report_incident(p_fingerprint text, p_source text, p_severity text, p_affected_operation text, p_affected_release text, p_evidence jsonb) from public, anon, authenticated;
revoke all on function public.muster_engine_resolve_alert(p_id bigint, p_status text, p_error text) from public, anon, authenticated;
revoke all on function public.muster_engine_resolve_api_key(p_key text) from public, anon, authenticated;
revoke all on function public.muster_engine_search_evidence(p_ctx jsonb, p_website_id bigint, p_embedding vector, p_limit integer, p_threshold double precision) from public, anon, authenticated;
revoke all on function public.muster_engine_search_findings(p_ctx jsonb, p_website_id bigint, p_embedding vector, p_limit integer, p_threshold double precision) from public, anon, authenticated;
revoke all on function public.muster_engine_secret() from public, anon, authenticated;
revoke all on function public.muster_engine_sitrep(p_scan_id bigint) from public, anon, authenticated;
revoke all on function public.muster_engine_watchdog_summary() from public, anon, authenticated;
revoke all on function public.muster_find_auth_user_by_email(p_email text) from public, anon, authenticated;
revoke all on function public.muster_ghl_provision(p jsonb, p_auth_user_id uuid) from public, anon, authenticated;
revoke all on function public.muster_ghl_webhook_secret() from public, anon, authenticated;
revoke all on function public.muster_mark_website_verified(p_website_id bigint) from public, anon, authenticated;
