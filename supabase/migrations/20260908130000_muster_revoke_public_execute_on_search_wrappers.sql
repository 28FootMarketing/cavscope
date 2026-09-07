-- CROSS-TENANT DATA EXPOSURE. muster_engine_search_findings and
-- muster_engine_search_evidence were granted EXECUTE to PUBLIC, anon and
-- authenticated when the retrieval work added them. Both take p_ctx jsonb and
-- trust it completely for scopes and organization_id -- that mapping is supposed
-- to be produced by muster_engine_resolve_api_key inside the muster-agent edge
-- function, from a real mk_ API key.
--
-- Because they were reachable through PostgREST with the anon key (which is
-- public by design and ships in client-side JS), the edge function could be
-- bypassed entirely and p_ctx simply asserted by the caller.
--
-- Verified against the live project before this migration:
--   POST /rest/v1/rpc/muster_engine_search_findings
--   apikey: <anon>
--   {"p_ctx":{"scopes":["read"]}, "p_website_id":3, "p_embedding":[...], "p_threshold":0}
--   -> 200, real findings for that tenant
--
-- Note the org check could not save it either:
--   if v_key_org is not null and v_org <> v_key_org then raise 'forbidden'
-- Omitting organization_id from p_ctx leaves v_key_org null, so the check is
-- skipped rather than denied. Scopes are self-asserted the same way. The only
-- thing standing between an anonymous caller and every tenant's findings and
-- evidence was knowing the function name and iterating p_website_id.
--
-- muster_engine_agent_call, which fronts the other eleven tools, was already
-- correctly restricted to postgres and service_role. This restores these two to
-- that same pattern. The muster-agent edge function authenticates with
-- SUPABASE_SERVICE_ROLE_KEY, so its own calls are unaffected.
--
-- Verified after: the same anon request returns
--   401 {"code":"42501","message":"permission denied for function muster_engine_search_findings"}
-- and the identical request with a service-role key still returns 200 with findings.

revoke execute on function public.muster_engine_search_findings(jsonb, bigint, public.vector, integer, double precision)
  from public, anon, authenticated;

revoke execute on function public.muster_engine_search_evidence(jsonb, bigint, public.vector, integer, double precision)
  from public, anon, authenticated;

grant execute on function public.muster_engine_search_findings(jsonb, bigint, public.vector, integer, double precision)
  to service_role;

grant execute on function public.muster_engine_search_evidence(jsonb, bigint, public.vector, integer, double precision)
  to service_role;
