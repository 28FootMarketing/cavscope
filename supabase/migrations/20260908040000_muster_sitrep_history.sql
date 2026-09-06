-- sitrep.html gap: no way to browse a website's past SITREPs -- only the
-- latest (muster_latest_sitrep) or one by direct id (muster_sitrep), no
-- listing RPC existed at all. For a product whose pitch is a dated,
-- cited situation report, being unable to show "what did our posture look
-- like as of last month" is a real limitation on the one screen built to
-- present exactly that history.
create or replace function public.muster_sitrep_history(p_website_id bigint, p_limit integer default 20)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not muster.is_org_member(muster.website_org(p_website_id)) then raise exception 'forbidden' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', sr.id, 'version', sr.version, 'status', sr.status,
      'generated_at', sr.generated_at, 'headline', sr.headline, 'posture_score', sr.posture_score,
      'posture_band', sr.posture_band, 'scan_id', sr.scan_id) order by sr.generated_at desc)
    from (select * from muster.sitreps where website_id = p_website_id order by generated_at desc limit greatest(1, least(p_limit, 100))) sr
  ), '[]'::jsonb);
end;
$$;
revoke all on function public.muster_sitrep_history(bigint, integer) from public, anon;
grant execute on function public.muster_sitrep_history(bigint, integer) to authenticated;
