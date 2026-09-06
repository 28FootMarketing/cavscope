-- Super-admin ad-hoc URL runner.
--
-- Consolidating the marketing demo surfaces to one (onboarding.html's scripted
-- "pre-flight scan" simulation is retired in favor of the real sample SITREP --
-- see middleware.js) means the super admin needs a real replacement for what
-- that simulation used to fake: showing a prospect their *actual* site being
-- scanned. This gives Anthony a clean way to type any URL into the admin
-- console, run it through the real scan engine, and read back real findings --
-- reusing muster.do_add_website / muster.do_request_scan as-is rather than
-- inventing a second scan path.
--
-- Ad-hoc prospect URLs must never land in a real tenant's risk register, so
-- they're parked in one dedicated, always-empty internal org (is_admin_sandbox)
-- instead of any live customer's organization_id.

alter table muster.organizations add column if not exists is_admin_sandbox boolean not null default false;

create unique index if not exists muster_organizations_admin_sandbox_uq
  on muster.organizations (is_admin_sandbox) where is_admin_sandbox;

-- Org 4 ("28 Foot Systems") is the existing internal-plan org with zero
-- websites attached -- already the right shape, just needs the marker.
update muster.organizations set is_admin_sandbox = true where id = 4 and name = '28 Foot Systems';

create or replace function muster.admin_sandbox_org()
returns bigint language plpgsql security definer set search_path = '' as $$
declare v_org bigint;
begin
  select id into v_org from muster.organizations where is_admin_sandbox limit 1;
  if v_org is not null then return v_org; end if;
  insert into muster.organizations (name, plan, country_code, onboarding_status, is_admin_sandbox)
  values ('MUSTER Admin — Ad Hoc Scans', 'internal', 'US', 'complete', true)
  returning id into v_org;
  return v_org;
end;
$$;

create or replace function public.muster_admin_run_url(p_url text, p_name text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_org bigint;
  v_url text := trim(coalesce(p_url, ''));
  v_website_id bigint;
  v_result jsonb;
  v_created boolean := false;
begin
  if not muster.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  if v_url = '' then raise exception 'a url is required' using errcode = '22023'; end if;
  if v_url !~* '^https?://' then v_url := 'https://' || v_url; end if;
  if v_url !~* '^https?://[a-z0-9.-]+\.[a-z]{2,}(:[0-9]+)?(/.*)?$' then
    raise exception 'not a valid url, for example https://example.com' using errcode = '22023';
  end if;

  v_org := muster.admin_sandbox_org();
  select id into v_website_id from muster.websites where organization_id = v_org and lower(url) = lower(v_url) limit 1;

  if v_website_id is null then
    v_result := muster.do_add_website(v_org, coalesce(nullif(trim(p_name), ''), v_url), v_url, 'production', 10080, muster.current_user_id(), 'manual');
    v_created := true;
  else
    v_result := jsonb_build_object('website_id', v_website_id, 'url', v_url,
      'first_scan', muster.do_request_scan(v_website_id, muster.current_user_id(), null, 'manual'));
  end if;

  return v_result || jsonb_build_object('created', v_created);
end;
$$;
revoke all on function public.muster_admin_run_url(text, text) from public, anon;
grant execute on function public.muster_admin_run_url(text, text) to authenticated;

-- Same shape a tenant sees for their own site (score, band, findings, recent
-- scans, latest sitrep) -- just gated on super-admin instead of org membership,
-- since the admin sandbox org has no real members.
create or replace function public.muster_admin_website_overview(p_website_id bigint)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not muster.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  return muster.q_website_overview(p_website_id);
end;
$$;
revoke all on function public.muster_admin_website_overview(bigint) from public, anon;
grant execute on function public.muster_admin_website_overview(bigint) to authenticated;

-- History of every URL run through the admin console, most recent first.
create or replace function public.muster_admin_url_runs(p_limit integer default 30)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_org bigint;
begin
  if not muster.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  select id into v_org from muster.organizations where is_admin_sandbox limit 1;
  if v_org is null then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(muster.q_website_summary(w.id) order by w.created_at desc)
    from (select * from muster.websites where organization_id = v_org order by created_at desc limit greatest(1, least(p_limit, 100))) w
  ), '[]'::jsonb);
end;
$$;
revoke all on function public.muster_admin_url_runs(integer) from public, anon;
grant execute on function public.muster_admin_url_runs(integer) to authenticated;
