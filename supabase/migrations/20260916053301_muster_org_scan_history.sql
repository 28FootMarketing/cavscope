-- MUSTER: tenant-wide (org-wide) audit run history.
-- muster.scans already retains every audit run forever, scoped by organization_id, but the
-- only read path (public.muster_scans) is per-website and capped at 100 rows. A tenant with
-- more than one website has no way to see all of its audit runs in one place. This adds that
-- read path: paginated, filterable by website and status, ordered newest first, with a total
-- count for the caller to page against.

create index if not exists scans_org_created_idx on muster.scans (organization_id, created_at desc);

create or replace function muster.q_org_scans(p_org bigint, p_limit integer default 25, p_offset integer default 0, p_website_id bigint default null, p_status text default null)
returns jsonb language sql stable security definer set search_path = '' as $$
  with filtered as (
    select s.*, w.name as website_name, w.url as website_url
    from muster.scans s
    join muster.websites w on w.id = s.website_id
    where s.organization_id = p_org
      and (p_website_id is null or s.website_id = p_website_id)
      and (p_status is null or s.status = p_status)
  )
  select jsonb_build_object(
    'total', (select count(*) from filtered),
    'rows', coalesce((
      select jsonb_agg(to_jsonb(f) order by f.created_at desc)
      from (
        select * from filtered order by created_at desc
        limit greatest(1, least(p_limit, 100)) offset greatest(0, p_offset)
      ) f
    ), '[]'::jsonb)
  );
$$;

create or replace function public.muster_org_scans(p_organization_id bigint, p_limit integer default 25, p_offset integer default 0, p_website_id bigint default null, p_status text default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not muster.is_org_member(p_organization_id) then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_status is not null and p_status not in ('queued','running','complete','failed') then
    raise exception 'invalid status %', p_status using errcode = '22023';
  end if;
  if p_website_id is not null and muster.website_org(p_website_id) is distinct from p_organization_id then
    raise exception 'website % not in organization %', p_website_id, p_organization_id using errcode = 'P0002';
  end if;
  return muster.q_org_scans(p_organization_id, p_limit, p_offset, p_website_id, p_status);
end;
$$;

revoke execute on function public.muster_org_scans(bigint, integer, integer, bigint, text) from public, anon, authenticated;
grant execute on function public.muster_org_scans(bigint, integer, integer, bigint, text) to authenticated;
grant execute on function public.muster_org_scans(bigint, integer, integer, bigint, text) to service_role;
