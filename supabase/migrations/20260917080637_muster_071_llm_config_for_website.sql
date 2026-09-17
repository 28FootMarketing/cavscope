-- muster_071: resolve a tenant's LLM from the WEBSITE being narrated, not from
-- the API key.
--
-- muster_070 gave the edge function muster_engine_llm_config(org). Wiring
-- muster-agent against it surfaced the problem that function cannot solve on
-- its own: the edge function would have to decide which org id to pass, and the
-- obvious source -- ctx.organization_id, off the API key -- is the wrong one.
--
-- muster_engine_agent_call resolves ai_narrative's target as
-- muster.website_org(website_id) and only refuses when the key IS org-scoped
-- and the orgs differ. A platform-scoped key (organization_id null: MUSTER's
-- own agents) may therefore narrate ANY tenant's site. Had the edge function
-- keyed off the API key, that path would have found no config for "no org",
-- and the natural-looking fix -- fall back to MUSTER's OpenRouter account --
-- would have sent a tenant's findings to our inference provider through the one
-- feature built to stop precisely that. Nothing would have failed. The tenant
-- would have had a configured endpoint, and their data would have gone
-- somewhere else.
--
-- So SQL does the mapping and the edge function never names an organization at
-- all: it names the website it was asked to narrate, and this decides whose
-- credential that is. There is no argument the caller can get wrong.
--
-- It delegates to muster_engine_llm_config rather than repeating the vault
-- join, so there stays exactly one function in the schema that reads a
-- decrypted tenant key.

create or replace function public.muster_engine_llm_config_for_website(p_website_id bigint)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to ''
as $function$
declare v_org bigint; v jsonb;
begin
  v_org := muster.website_org(p_website_id);
  -- Not an exception: the caller already failed to find this website through
  -- muster_engine_agent_call if it does not exist, and "not configured" is the
  -- safe answer either way -- it means no LLM call happens.
  if v_org is null then
    return jsonb_build_object('configured', false, 'reason', 'website not found');
  end if;

  v := public.muster_engine_llm_config(v_org);
  -- organization_id rides along so the engine can record the outcome against
  -- the right row without a second lookup. It is not a secret; the key is, and
  -- it is not added here -- muster_engine_llm_config already put it in v, which
  -- is why this function carries the same service-role-only grants.
  return v || jsonb_build_object('organization_id', v_org);
end;
$function$;

comment on function public.muster_engine_llm_config_for_website(bigint) is
  'Service role only. The LLM configuration (including the decrypted key) of the organization that owns p_website_id. The engine calls this instead of naming an organization, because the org on an API key is not necessarily the org that owns the site being narrated.';

-- Same grants as the function it wraps: it returns the same credential, so a
-- weaker ACL here would make muster_070's revokes decorative. Revoked from
-- anon AND authenticated by name, because Supabase's default privileges grant
-- EXECUTE on every new public function to both and `revoke ... from public`
-- does not undo it.
revoke all on function public.muster_engine_llm_config_for_website(bigint) from public, anon, authenticated;
grant execute on function public.muster_engine_llm_config_for_website(bigint) to service_role;

do $$
begin
  if to_regprocedure('public.muster_engine_llm_config_for_website(bigint)') is null then
    raise exception 'muster_engine_llm_config_for_website was not created';
  end if;
  if has_function_privilege('anon', 'public.muster_engine_llm_config_for_website(bigint)', 'execute') then
    raise exception 'muster_engine_llm_config_for_website is executable by anon -- it returns a tenant credential';
  end if;
  if has_function_privilege('authenticated', 'public.muster_engine_llm_config_for_website(bigint)', 'execute') then
    raise exception 'muster_engine_llm_config_for_website is executable by authenticated -- it returns a tenant credential';
  end if;

  -- Execute it, which is the check muster_067 lacked: a plpgsql body naming a
  -- function that does not exist applies cleanly and fails at call time.
  -- -1 is no website, so this proves the call path without touching a tenant.
  if (public.muster_engine_llm_config_for_website(-1) ->> 'configured') <> 'false' then
    raise exception 'muster_engine_llm_config_for_website(-1) should report not configured';
  end if;
end $$;
