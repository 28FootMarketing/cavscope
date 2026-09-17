-- muster_067: the last two things the console could not show.
--
-- The standalone console renders fourteen sections from one read, and every
-- platform WRITE action still lived only in app.html's superadmin view: flags,
-- plans, roles, incident triage, pricing. Those are all being moved to the
-- console, and five of them need nothing from this migration -- the data is
-- already in muster_admin_console() and the RPCs exist, so they were only ever
-- missing their controls.
--
-- Three more had no data here at all. Impersonation needs none either: its five
-- RPCs are already super-admin gated and callable, and a live session's status
-- has to be read fresh rather than cached in a page-load payload, so the console
-- calls them directly. That leaves the two static lists below, which belong in
-- the one read the page already does.
--
-- platform_agents is deliberately organization_id IS NULL. A tenant's own agents
-- are that tenant's business and appear in their workspace; these are the
-- platform-level keys, which is what a platform console is for. Key material is
-- never returned -- only the prefix, scopes and usage -- because the hash is all
-- the database has and the plaintext existed once, at issue.
--
-- jurisdiction_review_queue is the same 180-day query muster_admin_overview()
-- has always used. It is a research task, not an automated one: a law row nobody
-- has re-read in six months may be wrong, and nothing in the schema can tell.

create or replace function public.muster_admin_console()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to ''
as $function$
declare v jsonb;
begin
  if not muster.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;

  -- Everything the console already returned, unchanged.
  v := public.muster_admin_console_base();

  return v || jsonb_build_object(
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
        'laws', (select count(*) from muster.jurisdiction_laws l where l.jurisdiction_code = j.code)
        ) order by j.reviewed_at nulls first), '[]'::jsonb)
      from muster.jurisdictions j
      where j.reviewed_at is null or j.reviewed_at < current_date - interval '180 days')
  );
end;
$function$;

revoke all on function public.muster_admin_console() from public, anon;
grant execute on function public.muster_admin_console() to authenticated, service_role;
