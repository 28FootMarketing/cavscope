-- TEMPORARY. Dropped by muster_034 in the same session.
--
-- muster_ghl_webhook_secret is in mgtmqucaldkaxvxglguw's vault and missing from
-- this project's. public.muster_ghl_webhook_secret() reads it by name, and
-- muster-ghl-webhook compares it to the x-muster-secret header GHL sends -- so
-- with the entry absent the RPC returns null and the function 401s every
-- request. The value has to match what GHL is already configured to send, so it
-- is copied rather than regenerated: that leaves GHL needing only a URL change
-- at cutover, not a secret change too.
--
-- Same reasoning as muster_030: the value is credential material, so it moves
-- server-to-server over pg_net instead of appearing as a literal in a statement,
-- a transcript, or this file.
--
-- Idempotent on name: vault.create_secret raises on duplicate, so an existing
-- entry is updated in place instead.
--
-- The token below is single-use and dead once muster_034 drops this function.
-- Do not reuse the value.

create or replace function public.muster_vault_import(p_token text, p_name text, p_secret text)
returns jsonb
language plpgsql
security definer
set search_path = public, vault, pg_temp
as $fn$
declare
  v_id uuid;
  v_action text;
begin
  if p_token is null or p_token <> '905238b70d9b369aca09cf2305b52944f5262a6907d46a42' then
    raise exception 'unauthorized';
  end if;
  if p_name is null or p_secret is null or length(p_secret) = 0 then
    raise exception 'name and secret are both required';
  end if;

  select id into v_id from vault.secrets where name = p_name;

  if v_id is null then
    perform vault.create_secret(p_secret, p_name, 'copied from mgtmqucaldkaxvxglguw at cutover');
    v_action := 'created';
  else
    perform vault.update_secret(v_id, p_secret, p_name, 'copied from mgtmqucaldkaxvxglguw at cutover');
    v_action := 'updated';
  end if;

  return jsonb_build_object('name', p_name, 'action', v_action, 'len', length(p_secret));
end
$fn$;

revoke all on function public.muster_vault_import(text, text, text) from public;
grant execute on function public.muster_vault_import(text, text, text) to anon, authenticated, service_role;
