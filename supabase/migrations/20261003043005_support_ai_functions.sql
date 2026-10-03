-- Three engine functions for AI support triage. All service_role only; each revoked from public, anon and
-- authenticated by name, as every engine function must be.
--
-- cavscope_engine_support_ai_enabled: the flag, read the way the console shows it. On only when the flag
--   exists, its default is on and its kill switch is off. A missing row is off.
-- cavscope_engine_support_context: a few facts about the request's organization for the model to rule
--   things in or out. Plan, limits, up to five sites, the last five scans, the open platform incidents and
--   the latest report's date and score. No names, emails or findings text.
-- cavscope_engine_finish_support_ai: records the model's answer, or why there is none.

create or replace function public.cavscope_engine_support_ai_enabled()
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select f.default_enabled and not f.kill_switch from cavscope.feature_flags f where f.key = 'support_ai'), false);
$$;
revoke all on function public.cavscope_engine_support_ai_enabled() from public, anon, authenticated;
grant execute on function public.cavscope_engine_support_ai_enabled() to service_role;

create or replace function public.cavscope_engine_support_context(p_id bigint)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare r record; v_org bigint; o jsonb; w jsonb; s jsonb; i jsonb; sr jsonb;
begin
  select * into r from cavscope.support_requests where id = p_id;
  if not found then return null; end if;
  v_org := r.organization_id;
  select jsonb_build_object('plan', plan, 'website_limit', website_limit, 'commercial_stage', commercial_stage, 'onboarding_status', onboarding_status, 'is_partner_client', managed_by_org_id is not null)
    into o from cavscope.organizations where id = v_org;
  select coalesce(jsonb_agg(jsonb_build_object('url', x.url, 'environment', x.environment, 'verified', x.verified_at is not null)), '[]'::jsonb)
    into w from (select url, environment, verified_at from cavscope.websites where organization_id = v_org order by id limit 5) x;
  select coalesce(jsonb_agg(jsonb_build_object('status', x.status, 'trigger', x.trigger, 'engine_version', x.engine_version, 'http_status', x.http_status, 'finished_at', x.finished_at, 'error', left(x.error_message, 200))), '[]'::jsonb)
    into s from (select status, trigger, engine_version, http_status, finished_at, error_message from cavscope.scans where organization_id = v_org order by id desc limit 5) x;
  select coalesce(jsonb_agg(jsonb_build_object('source', x.source, 'severity', x.severity, 'status', x.status, 'last_seen_at', x.last_seen_at)), '[]'::jsonb)
    into i from (select source, severity, status, last_seen_at from cavscope.incidents where status <> 'closed' order by last_seen_at desc limit 8) x;
  select jsonb_build_object('generated_at', generated_at, 'posture_score', posture_score, 'posture_band', posture_band)
    into sr from cavscope.sitreps where organization_id = v_org order by id desc limit 1;
  return jsonb_build_object('organization', o, 'websites', w, 'recent_scans', s, 'open_platform_incidents', i, 'latest_report', sr);
end;
$$;
revoke all on function public.cavscope_engine_support_context(bigint) from public, anon, authenticated;
grant execute on function public.cavscope_engine_support_context(bigint) to service_role;

create or replace function public.cavscope_engine_finish_support_ai(p_id bigint, p_status text, p_result jsonb default null, p_model text default null, p_error text default null)
returns void language sql security definer set search_path = '' as $$
  update cavscope.support_requests set
    ai_status = p_status,
    ai_kind = case when p_status = 'done' then p_result->>'kind' end,
    ai_confidence = case when p_status = 'done' then p_result->>'confidence' end,
    ai_summary = case when p_status = 'done' then left(p_result->>'summary', 600) end,
    ai_screen_notes = case when p_status = 'done' then left(p_result->>'screen_notes', 1200) end,
    ai_likely_cause = case when p_status = 'done' then left(p_result->>'likely_cause', 1200) end,
    ai_suggested_fix = case when p_status = 'done' then left(p_result->>'suggested_fix', 1600) end,
    ai_draft_reply = case when p_status = 'done' then left(p_result->>'draft_reply', 2400) end,
    ai_model = left(p_model, 100), ai_error = left(p_error, 300), ai_at = now()
  where id = p_id;
$$;
revoke all on function public.cavscope_engine_finish_support_ai(bigint, text, jsonb, text, text) from public, anon, authenticated;
grant execute on function public.cavscope_engine_finish_support_ai(bigint, text, jsonb, text, text) to service_role;

-- Read by the three functions above and by the cavscope-support-request function.
update cavscope.feature_flags set enforcement = array['sql','edge'], wiring_note = 'Read by public.cavscope_engine_support_ai_enabled and the cavscope-support-request function. Ships dark: kill switch on and default off until an owner turns it on in the console. It also needs CAVSCOPE_SUPPORT_OPENROUTER_KEY or OPENROUTER key present in the function environment.' where key = 'support_ai';
-- The note above named a key the function does not read. Corrected by a direct update after this
-- migration applied (the function reads MUSTER_OPENROUTER_API_KEY or OPENROUTER_API_KEY, and skips
-- quietly without one); the live row is the true text.
