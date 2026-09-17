-- muster_068: repair muster_admin_console(), which muster_067 broke, and add the
-- two lists it was trying to add -- this time without touching it.
--
-- WHAT 067 DID WRONG. It redefined muster_admin_console() as a thin wrapper that
-- called public.muster_admin_console_base() for the original payload and merged
-- two new keys onto it. No such function has ever existed. Postgres does not
-- resolve function calls inside a plpgsql body at definition time, so the
-- migration applied cleanly and the console then raised 42883 on every load --
-- the whole page, not one section. It was caught within a minute by checking
-- whether the name it referenced existed, and the definition was restored by
-- re-executing the original statement straight out of the migration ledger,
-- which is byte-exact and needs no retyping. 067's file is kept as what ran.
--
-- THE LESSON, written down because it will recur: a CREATE OR REPLACE that
-- applies successfully is not a working function. Postgres validates syntax, not
-- the existence of what the body calls. Anything replacing a live function has
-- to be exercised afterwards.
--
-- And note what this migration cannot do about that. The obvious guard -- call
-- muster_admin_console() here and check it returns -- does not work: it is gated
-- on muster.is_super_admin(), a migration runs with no JWT, and the call raises
-- 42501. That gap is exactly how 067 reached production, and it is why the check
-- below inspects the definition instead, and why a super-admin RPC still needs a
-- real signed-in load to be called verified.
--
-- WHAT THIS DOES INSTEAD. The two lists get their own small RPC rather than being
-- spliced into the 269-line console payload:
--
--   * Re-emitting that body to add two keys is the transcription risk this repo
--     already refuses for muster-scan, aimed at the function every section of
--     the console reads. The smaller change is the safer one.
--   * The page already makes more than one call -- muster_064 added the SITREP
--     index and body -- so "everything comes from one RPC" stopped being true
--     before this, and CLAUDE.md is corrected to say so.
--   * Two sections want these lists (Integrations, Compliance) and twelve do
--     not, so loading them with the main payload was never the right shape.
--
-- platform_agents is deliberately organization_id IS NULL: a tenant's own agents
-- are that tenant's business and show in their workspace. Key material is never
-- returned -- only prefix, scopes and usage -- because the hash is all the
-- database has and the plaintext existed once, at issue.
--
-- jurisdiction_review_queue is the 180-day query muster_admin_overview() has
-- always used, plus rows never reviewed at all, which it missed: a bare
-- `reviewed_at < current_date - 180` excludes NULL, so a jurisdiction nobody had
-- ever checked never appeared in the queue asking someone to check it.

create or replace function public.muster_admin_platform_extras()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to ''
as $function$
begin
  if not muster.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;

  return jsonb_build_object(
    'platform_agents', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', a.id, 'name', a.name, 'kind', a.kind, 'active', a.active,
        'created_at', a.created_at,
        'keys', (select coalesce(jsonb_agg(jsonb_build_object(
            'id', k.id, 'key_prefix', k.key_prefix, 'name', k.name,
            'scopes', to_jsonb(k.scopes), 'last_used_at', k.last_used_at,
            'revoked_at', k.revoked_at, 'expires_at', k.expires_at) order by k.id), '[]'::jsonb)
          from muster.api_keys k where k.agent_id = a.id)) order by a.created_at desc), '[]'::jsonb)
      from muster.agents a where a.organization_id is null),

    'jurisdiction_review_queue', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'code', j.code, 'name', j.name, 'reviewed_at', j.reviewed_at,
        'never_reviewed', j.reviewed_at is null,
        'laws', (select count(*) from muster.jurisdiction_laws l where l.jurisdiction_code = j.code)
        ) order by j.reviewed_at nulls first), '[]'::jsonb)
      from muster.jurisdictions j
      where j.reviewed_at is null or j.reviewed_at < current_date - interval '180 days')
  );
end;
$function$;

comment on function public.muster_admin_platform_extras() is
  'Platform-level agents and API keys, and the jurisdictions overdue for human review. Two lists the Super Admin console needs and the main console payload does not carry. Super admin only.';

revoke all on function public.muster_admin_platform_extras() from public, anon;
grant execute on function public.muster_admin_platform_extras() to authenticated, service_role;

-- The guard 067 needed. It cannot call the function (see the header), so it
-- checks the definition for the dangling reference instead, and asserts the new
-- one exists and is reachable by a signed-in session and not by anon.
do $$
begin
  if pg_get_functiondef('public.muster_admin_console()'::regprocedure) ~ 'muster_admin_console_base' then
    raise exception 'muster_admin_console() still references muster_admin_console_base(), which does not exist';
  end if;

  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'muster_admin_platform_extras'
  ) then
    raise exception 'muster_admin_platform_extras() was not created';
  end if;

  if has_function_privilege('anon', 'public.muster_admin_platform_extras()', 'execute') then
    raise exception 'muster_admin_platform_extras() is executable by anon';
  end if;

  if not has_function_privilege('authenticated', 'public.muster_admin_platform_extras()', 'execute') then
    raise exception 'muster_admin_platform_extras() is not executable by authenticated';
  end if;
end $$;
