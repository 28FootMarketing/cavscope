-- muster_064: a platform-wide SITREP index, so the console can show the report
-- it just generated.
--
-- admin.html's Reports section has been a stub since the console shipped, and
-- its own text named the gap exactly: "What is missing here is a platform-wide
-- index across tenants, which needs its own RPC." This is that RPC.
--
-- Why it was actually noticed: the Audit Queue can now start a scan, and a scan
-- writes a SITREP about a second later. Someone ran one and had nowhere to read
-- the result -- the report existed, in muster.sitreps, with nothing in the
-- product pointing at it. Generating a deliverable and not showing it is the
-- same class of failure as a switch that changes nothing.
--
-- Two functions rather than one. The index is small and loads with the section;
-- content_md is up to a few KB per report and is fetched only for the report
-- actually opened, so a console with a few hundred SITREPs does not pull all of
-- their markdown to render a list.
--
-- Tenant-facing SITREP reading is unchanged: sitrep.html and muster_sitrep()
-- still serve tenants under RLS. These two are super-admin-only and cross-tenant
-- by design, which is the whole point of a platform console, and they are gated
-- the same way as every other muster_admin_* RPC.

create or replace function public.muster_admin_sitreps(p_limit integer default 100)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to ''
as $function$
begin
  if not muster.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;

  return coalesce((
    select jsonb_agg(x order by x->>'generated_at' desc)
    from (
      select jsonb_build_object(
        'id', s.id,
        'scan_id', s.scan_id,
        'website_id', s.website_id,
        'website', w.name,
        'url', w.url,
        'organization_id', o.id,
        'organization', o.name,
        'is_admin_sandbox', coalesce(o.is_admin_sandbox, false),
        'status', s.status,
        -- deterministic-v1 or the LLM narrative generator. Worth showing: a
        -- reader should know whether prose was written by a template or a model
        -- before quoting it to a client.
        'generator', s.generator,
        'posture_score', s.posture_score,
        'posture_band', s.posture_band,
        'headline', s.headline,
        'version', s.version,
        'generated_at', s.generated_at,
        'engine_version', sc.engine_version,
        'citations', jsonb_array_length(coalesce(s.citations, '[]'::jsonb))
      ) as x
      from muster.sitreps s
      join muster.websites w on w.id = s.website_id
      join muster.organizations o on o.id = s.organization_id
      left join muster.scans sc on sc.id = s.scan_id
      order by s.generated_at desc
      limit greatest(1, least(coalesce(p_limit, 100), 500))
    ) t
  ), '[]'::jsonb);
end;
$function$;

comment on function public.muster_admin_sitreps(integer) is
  'Platform-wide SITREP index for the Super Admin console: every generated report across every tenant, newest first, without their markdown. Super admin only.';

create or replace function public.muster_admin_sitrep(p_id bigint)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to ''
as $function$
declare v jsonb;
begin
  if not muster.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;

  select to_jsonb(s) || jsonb_build_object(
    'website', w.name, 'url', w.url,
    'organization', o.name, 'is_admin_sandbox', coalesce(o.is_admin_sandbox, false),
    'engine_version', sc.engine_version)
  into v
  from muster.sitreps s
  join muster.websites w on w.id = s.website_id
  join muster.organizations o on o.id = s.organization_id
  left join muster.scans sc on sc.id = s.scan_id
  where s.id = p_id;

  if v is null then raise exception 'no such sitrep' using errcode = 'P0002'; end if;
  return v;
end;
$function$;

comment on function public.muster_admin_sitrep(bigint) is
  'One SITREP with its full content_md, for the Super Admin console. Super admin only; tenants read their own through muster_sitrep() under RLS.';

-- Supabase grants EXECUTE on every new public function to anon and
-- authenticated by default, and `revoke ... from public` does not undo it.
revoke all on function public.muster_admin_sitreps(integer) from public, anon;
revoke all on function public.muster_admin_sitrep(bigint) from public, anon;
grant execute on function public.muster_admin_sitreps(integer) to authenticated, service_role;
grant execute on function public.muster_admin_sitrep(bigint) to authenticated, service_role;
