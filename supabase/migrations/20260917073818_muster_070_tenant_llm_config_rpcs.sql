-- muster_070: the RPCs around a tenant's own LLM key.
--
-- The shape of this is set by one fact: the stored value is a credential for
-- someone else's billable account. So there are two read paths and they are not
-- the same function. muster_llm_config() is what a browser may call and returns
-- a four-character hint; muster_engine_llm_config() returns the key itself and
-- is service-role only, revoked from anon and authenticated BY NAME, per the
-- standing rule -- Supabase's default privileges grant EXECUTE on every new
-- public function to both roles and `revoke ... from public` does not undo it.
-- Getting that wrong here does not leak a scan result, it leaks a customer's
-- API key.
--
-- Writes are org executive or super admin. A contributor can read that a key is
-- configured and cannot set one.

create or replace function public.muster_set_llm_config(
  p_organization_id bigint, p_base_url text, p_model text,
  p_api_key text, p_label text default null)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  v_url    text := btrim(coalesce(p_base_url, ''));
  v_model  text := btrim(coalesce(p_model, ''));
  v_key    text := btrim(coalesce(p_api_key, ''));
  v_name   text;
  v_sid    uuid;
  v_exist  uuid;
begin
  if not (muster.is_org_executive(p_organization_id) or muster.is_super_admin()) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if not muster.has_flag(p_organization_id, 'ai_narrative') then
    raise exception 'the AI narrative feature is not enabled for this organization' using errcode = '42501';
  end if;
  if not muster.is_valid_llm_endpoint(v_url) then
    raise exception 'the endpoint must be an absolute https URL on a public host. Loopback, private and link-local addresses are refused.'
      using errcode = '22023';
  end if;
  if v_model = '' then raise exception 'a model name is required' using errcode = '22023'; end if;
  if length(v_key) < 8 then raise exception 'that does not look like an API key' using errcode = '22023'; end if;

  select secret_id into v_exist from muster.org_llm_config where organization_id = p_organization_id;
  v_name := 'muster_llm_org_' || p_organization_id::text;

  if v_exist is null then
    v_sid := vault.create_secret(v_key, v_name, 'Tenant-supplied LLM API key for MUSTER organization ' || p_organization_id::text);
  else
    -- Rotating in place keeps the id stable, so nothing else has to be updated
    -- and no orphan secret is left holding a live key.
    perform vault.update_secret(v_exist, v_key, v_name, 'Tenant-supplied LLM API key for MUSTER organization ' || p_organization_id::text);
    v_sid := v_exist;
  end if;

  insert into muster.org_llm_config
    (organization_id, label, base_url, model, secret_id, key_hint, enabled, created_by_id,
     last_ok_at, last_error, last_error_at)
  values
    (p_organization_id, left(nullif(btrim(coalesce(p_label, '')), ''), 80), v_url, left(v_model, 160),
     v_sid, right(v_key, 4), true, muster.current_user_id(), null, null, null)
  on conflict (organization_id) do update set
    label = excluded.label, base_url = excluded.base_url, model = excluded.model,
    secret_id = excluded.secret_id, key_hint = excluded.key_hint, enabled = true,
    -- A new key clears the previous failure, or the UI would keep showing an
    -- error about a credential that no longer exists.
    last_ok_at = null, last_error = null, last_error_at = null;

  return public.muster_llm_config(p_organization_id);
end;
$function$;

-- The browser-facing read. Deliberately returns no secret and no secret_id.
create or replace function public.muster_llm_config(p_organization_id bigint)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to ''
as $function$
declare v jsonb;
begin
  if not muster.is_org_member(p_organization_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'configured', true,
    'organization_id', c.organization_id,
    'label', c.label,
    'base_url', c.base_url,
    'model', c.model,
    'key_hint', c.key_hint,
    'enabled', c.enabled,
    'last_ok_at', c.last_ok_at,
    'last_error', c.last_error,
    'last_error_at', c.last_error_at,
    'updated_at', c.updated_at)
  into v
  from muster.org_llm_config c where c.organization_id = p_organization_id;

  -- Not configured is a normal state, not an error: it means this tenant gets
  -- the deterministic generator and nothing of theirs reaches any LLM.
  return coalesce(v, jsonb_build_object('configured', false, 'organization_id', p_organization_id));
end;
$function$;

create or replace function public.muster_clear_llm_config(p_organization_id bigint)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare v_sid uuid;
begin
  if not (muster.is_org_executive(p_organization_id) or muster.is_super_admin()) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  select secret_id into v_sid from muster.org_llm_config where organization_id = p_organization_id;
  delete from muster.org_llm_config where organization_id = p_organization_id;
  -- Remove the credential itself, not just the row pointing at it. A deleted
  -- config that leaves a live key in the vault is a key nobody is watching.
  if v_sid is not null then delete from vault.secrets where id = v_sid; end if;

  return jsonb_build_object('configured', false, 'organization_id', p_organization_id, 'cleared', v_sid is not null);
end;
$function$;

-- Service role only. This is the one function that returns the key.
create or replace function public.muster_engine_llm_config(p_organization_id bigint)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to ''
as $function$
declare v jsonb;
begin
  select jsonb_build_object(
    'configured', true,
    'base_url', c.base_url,
    'model', c.model,
    'api_key', s.decrypted_secret)
  into v
  from muster.org_llm_config c
  join vault.decrypted_secrets s on s.id = c.secret_id
  where c.organization_id = p_organization_id and c.enabled;

  return coalesce(v, jsonb_build_object('configured', false));
end;
$function$;

-- So an expired or revoked tenant key is visible instead of degrading to
-- silence. The engine calls this after every attempt.
create or replace function public.muster_engine_record_llm_result(
  p_organization_id bigint, p_ok boolean, p_error text default null)
 returns void
 language plpgsql
 security definer
 set search_path to ''
as $function$
begin
  if p_ok then
    update muster.org_llm_config
       set last_ok_at = now(), last_error = null, last_error_at = null
     where organization_id = p_organization_id;
  else
    update muster.org_llm_config
       set last_error = left(coalesce(p_error, 'unknown error'), 500), last_error_at = now()
     where organization_id = p_organization_id;
  end if;
end;
$function$;

-- Grants. The engine pair is revoked from anon AND authenticated by name: a
-- browser holding the publishable key must never reach the function that
-- returns a decrypted credential.
revoke all on function public.muster_engine_llm_config(bigint) from public, anon, authenticated;
revoke all on function public.muster_engine_record_llm_result(bigint, boolean, text) from public, anon, authenticated;
grant execute on function public.muster_engine_llm_config(bigint) to service_role;
grant execute on function public.muster_engine_record_llm_result(bigint, boolean, text) to service_role;

revoke all on function public.muster_set_llm_config(bigint, text, text, text, text) from public, anon;
revoke all on function public.muster_llm_config(bigint) from public, anon;
revoke all on function public.muster_clear_llm_config(bigint) from public, anon;
grant execute on function public.muster_set_llm_config(bigint, text, text, text, text) to authenticated, service_role;
grant execute on function public.muster_llm_config(bigint) to authenticated, service_role;
grant execute on function public.muster_clear_llm_config(bigint) to authenticated, service_role;

-- The guard muster_067 needed. Postgres does not resolve calls inside a plpgsql
-- body at definition time, so a migration applying cleanly proves nothing about
-- whether the function works. These assertions are what this migration can
-- actually check: that every function it just defined exists, and that the two
-- returning or touching a credential are unreachable from a browser.
do $$
declare fn text;
begin
  foreach fn in array array[
    'public.muster_set_llm_config(bigint,text,text,text,text)',
    'public.muster_llm_config(bigint)',
    'public.muster_clear_llm_config(bigint)',
    'public.muster_engine_llm_config(bigint)',
    'public.muster_engine_record_llm_result(bigint,boolean,text)'
  ] loop
    if to_regprocedure(fn) is null then raise exception '% was not created', fn; end if;
  end loop;

  for fn in select unnest(array[
    'public.muster_engine_llm_config(bigint)',
    'public.muster_engine_record_llm_result(bigint,boolean,text)'
  ]) loop
    if has_function_privilege('anon', fn, 'execute') then
      raise exception '% is executable by anon', fn;
    end if;
    if has_function_privilege('authenticated', fn, 'execute') then
      raise exception '% is executable by authenticated -- it returns or touches a tenant credential', fn;
    end if;
  end loop;

  if has_function_privilege('anon', 'public.muster_llm_config(bigint)', 'execute') then
    raise exception 'muster_llm_config is executable by anon';
  end if;

  -- And prove the engine read actually runs rather than merely existing, which
  -- is the specific thing 067 failed to check.
  perform public.muster_engine_llm_config(-1);
end $$;
