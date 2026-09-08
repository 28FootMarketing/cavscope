-- Fixes two grant gaps the ACL checksum caught after muster_021.
--
-- 1. My blanket "revoke all ... from public, anon, authenticated" also took
--    service_role's access with it on 24 muster.* functions, because on this
--    project service_role only ever held it through the default PUBLIC grant.
--    The edge functions run as service_role, so the engine would have been
--    locked out of its own internals. Source grants service_role explicitly.
--
-- 2. 68 functions still carried Postgres's default PUBLIC grant, which source
--    does not have. PUBLIC includes anon, so on this project anon could call
--    every admin RPC and every authorization helper. The bodies check
--    is_super_admin() and would have raised, so it is not an open door -- but it
--    is a wider surface than source, and "it fails safely" is not the same as
--    "it is not reachable".
--
-- Driven off name lists rather than restated signatures, so argument lists are
-- read from this project's own catalog and cannot be mistyped.
do $$
declare
  r record;
  svc_only text[] := array[
    'agent_tools','do_add_website','do_onboard','do_promote_finding','do_request_scan',
    'do_update_finding_status','engine_claim','engine_fail','engine_ingest','ensure_user_from_auth',
    'generate_sitrep','q_brand','q_compliance_posture','q_evidence','q_findings','q_flags',
    'q_jurisdiction_advisory','q_latest_sitrep','q_organization','q_scans','q_sitrep',
    'q_website_overview','q_website_summary','touch_updated_at'];
  auth_helpers text[] := array[
    'can_write_org','control_org','current_user_id','evidence_org','finding_fingerprint','has_flag',
    'is_org_executive','is_org_member','is_super_admin','org_role','posture_band','posture_score',
    'remediation_org','risk_org','severity_rank','severity_weight','shares_org_with','website_org'];
  locked_shims text[] := array[
    'muster_engine_agent_call','muster_engine_agent_tools','muster_engine_claim','muster_engine_claim_alerts',
    'muster_engine_cron_health_check','muster_engine_fail','muster_engine_ingest',
    'muster_engine_record_commercial_grant','muster_engine_report_incident','muster_engine_resolve_alert',
    'muster_engine_resolve_api_key','muster_engine_search_evidence','muster_engine_search_findings',
    'muster_engine_secret','muster_engine_sitrep','muster_engine_watchdog_summary',
    'muster_find_auth_user_by_email','muster_ghl_provision','muster_ghl_webhook_secret',
    'muster_mark_website_verified'];
  anon_shims text[] := array[
    'muster_countries','muster_jurisdiction_advisory','muster_plans','muster_public_pricing','muster_regions'];
begin
  for r in
    select p.proname,
           format('%I.%I(%s)', n.nspname, p.proname, pg_get_function_identity_arguments(p.oid)) as sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'muster' and p.proname = any (svc_only)
  loop
    execute format('grant execute on function %s to service_role', r.sig);
  end loop;

  for r in
    select p.proname,
           format('%I.%I(%s)', n.nspname, p.proname, pg_get_function_identity_arguments(p.oid)) as sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'muster' and p.proname = any (auth_helpers)
  loop
    execute format('revoke all on function %s from public, anon', r.sig);
    execute format('grant execute on function %s to authenticated, service_role', r.sig);
  end loop;

  for r in
    select p.proname,
           format('%I.%I(%s)', n.nspname, p.proname, pg_get_function_identity_arguments(p.oid)) as sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname like 'muster%' and not (p.proname = any (locked_shims))
  loop
    execute format('revoke all on function %s from public, anon', r.sig);
    execute format('grant execute on function %s to authenticated, service_role', r.sig);
    if r.proname = any (anon_shims) then
      execute format('grant execute on function %s to anon', r.sig);
    end if;
  end loop;
end $$;
