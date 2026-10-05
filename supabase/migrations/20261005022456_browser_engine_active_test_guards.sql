-- Active tests send data to a site. Guards the foundation migration did not have:
--  * an authorization may name the endpoint hosts it covers (a form can post to a service the site owner
--    does not own; their say-so does not extend to it), and the worker re-checks before sending anything;
--  * at most 3 scans per domain per UTC day run the active tests; past that the scan still runs, without them.
--
-- Note on shape: a grant covers the site's own domain by default, and naming other hosts is a separate
-- explicit call (cavscope_set_scan_authorization_hosts). That was a drop-and-recreate of the grant function
-- first; it is two functions because the database connection used for this change hung on DROP statements,
-- and because "covers only my domain" is the right default for a grant anyway.
alter table cavscope.scan_authorizations add column if not exists endpoint_hosts text[] not null default '{}';

create or replace function public.cavscope_set_scan_authorization_hosts(p_authorization_id bigint, p_endpoint_hosts text[])
returns jsonb
language plpgsql security definer set search_path to ''
as $$
declare v_org bigint; v_site bigint; v_hosts text[];
begin
  select organization_id, website_id into v_org, v_site from cavscope.scan_authorizations where id = p_authorization_id and revoked_at is null;
  if v_org is null then raise exception 'authorization not found or revoked' using errcode = 'P0002'; end if;
  if cavscope.org_role(v_org) is distinct from 'executive' then raise exception 'forbidden' using errcode = '42501'; end if;
  select coalesce(array_agg(distinct lower(trim(h))) filter (where trim(h) <> ''), '{}') into v_hosts from unnest(p_endpoint_hosts) h;
  if exists (select 1 from unnest(v_hosts) h where h !~ '^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$') then
    raise exception 'endpoint hosts must be bare host names, for example abc.supabase.co' using errcode = '22023';
  end if;
  update cavscope.scan_authorizations set endpoint_hosts = v_hosts where id = p_authorization_id;
  insert into cavscope.activity_events (organization_id, entity_type, entity_id, action, detail, actor_id)
  values (v_org, 'website', v_site, 'Active-test endpoint hosts set',
          format('Authorization #%s now also covers: %s.', p_authorization_id, coalesce(nullif(array_to_string(v_hosts, ', '), ''), 'no extra hosts')),
          cavscope.current_user_id());
  return jsonb_build_object('authorization_id', p_authorization_id, 'endpoint_hosts', v_hosts);
end;
$$;
revoke all on function public.cavscope_set_scan_authorization_hosts(bigint, text[]) from public, anon;
grant execute on function public.cavscope_set_scan_authorization_hosts(bigint, text[]) to authenticated;

create or replace function cavscope.do_request_browser_scan(p_website_id bigint, p_user_id bigint, p_trigger text, p_cache_bust boolean, p_active_tests boolean)
returns jsonb
language plpgsql security definer set search_path to ''
as $$
declare
  v_org bigint; v_url text; v_existing bigint; v_scan_id bigint; v_auth bigint := null; v_opts jsonb; v_limited boolean := false;
begin
  select organization_id, url into v_org, v_url from cavscope.websites where id = p_website_id;
  if v_org is null then raise exception 'website % not found', p_website_id using errcode = 'P0002'; end if;

  select id into v_existing from cavscope.scans
   where website_id = p_website_id and engine = 'browser' and status in ('queued','running')
   order by created_at desc limit 1;
  if v_existing is not null then
    return jsonb_build_object('scan_id', v_existing, 'status', 'in_flight', 'deduplicated', true);
  end if;

  if p_active_tests and cavscope.flag_state_for_org(v_org, 'browser_active_tests') then
    v_auth := cavscope.active_test_authorization(p_website_id);
    -- Per domain, not per site record: the same domain registered twice does not double the allowance.
    if v_auth is not null and (
      select count(*) from cavscope.scans s join cavscope.websites w on w.id = s.website_id
       where s.engine = 'browser' and (s.options->>'active_tests')::boolean is true
         and cavscope.site_host(w.url) = cavscope.site_host(v_url)
         and s.created_at >= date_trunc('day', now() at time zone 'utc') at time zone 'utc'
    ) >= 3 then
      v_auth := null; v_limited := true;
    end if;
  end if;
  v_opts := jsonb_build_object(
    'cache_bust', coalesce(p_cache_bust, false),
    'active_tests_requested', coalesce(p_active_tests, false),
    'active_tests', v_auth is not null,
    'active_tests_limited', v_limited,
    'authorization_id', v_auth);

  insert into cavscope.scans (organization_id, website_id, trigger, status, requested_by_id, target_url, engine, options)
  values (v_org, p_website_id, p_trigger, 'queued', p_user_id, v_url, 'browser', v_opts)
  returning id into v_scan_id;

  insert into cavscope.activity_events (organization_id, entity_type, entity_id, action, detail, actor_id)
  values (v_org, 'scan', v_scan_id, 'Browser scan requested',
          format('Trigger: %s. Active tests: %s.', p_trigger,
                 case when v_auth is not null then 'authorized'
                      when v_limited then 'requested, daily limit of 3 per domain reached (skipped)'
                      when p_active_tests then 'requested, not authorized (skipped)' else 'not requested' end),
          p_user_id);

  return jsonb_build_object('scan_id', v_scan_id, 'status', 'queued', 'deduplicated', false, 'options', v_opts);
end;
$$;
revoke all on function cavscope.do_request_browser_scan(bigint, bigint, text, boolean, boolean) from public, anon, authenticated;

create or replace function cavscope.engine_claim_browser(p_scan_id bigint default null, p_limit integer default 1)
returns setof jsonb
language plpgsql security definer set search_path to ''
as $$
begin
  update cavscope.scans set status = 'failed', finished_at = now(),
    error_message = coalesce(error_message, 'Engine timeout: no result within 20 minutes')
   where engine = 'browser' and status = 'running' and started_at < now() - interval '20 minutes';

  return query
    with picked as (
      select s.id from cavscope.scans s
       where s.engine = 'browser' and s.status = 'queued' and (p_scan_id is null or s.id = p_scan_id)
       order by s.queued_at limit p_limit for update skip locked
    ), claimed as (
      update cavscope.scans s set status = 'running', started_at = now()
        from picked where s.id = picked.id returning s.*
    )
    select jsonb_build_object('scan_id', c.id, 'website_id', c.website_id, 'organization_id', c.organization_id,
      'target_url', c.target_url, 'website_name', w.name, 'trigger', c.trigger, 'options', c.options,
      'verified', w.verified_at is not null,
      'endpoint_hosts', coalesce((select to_jsonb(a.endpoint_hosts) from cavscope.scan_authorizations a
                                   where a.id = nullif(c.options->>'authorization_id', '')::bigint), '[]'::jsonb))
    from claimed c join cavscope.websites w on w.id = c.website_id;
end;
$$;
revoke all on function cavscope.engine_claim_browser(bigint, integer) from public, anon, authenticated;
