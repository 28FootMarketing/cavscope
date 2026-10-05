-- The browser engine runs as a Vercel function (api/browser-scan.mjs). It does not hold a service-role key.
-- It holds the public anon key and ONE shared secret, kept in Vault under cavscope_browser_worker_secret,
-- and these RPCs check that secret themselves. They are callable by anon (that is how the function reaches
-- PostgREST) and answer 42501 without it. This is a deliberate exception to "engine RPCs are revoked from
-- anon": the secret is what gates them, and each is narrowed to what the engine legitimately does:
--   * it can only claim queued scans whose engine is 'browser';
--   * it can only ingest into, or fail, a scan that is a RUNNING browser scan, so a leaked secret cannot
--     touch an HTTP scan, a finished scan, or anything else;
--   * it can read the open browser findings of a site (for the disappearance rule), nothing more.

do $$
begin
  if not exists (select 1 from vault.secrets where name = 'cavscope_browser_worker_secret') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'cavscope_browser_worker_secret',
      'Shared secret between the database and the Vercel browser-scan function');
  end if;
end $$;

create or replace function cavscope.worker_secret_ok(p_secret text) returns boolean
language sql stable security definer set search_path to ''
as $$
  select p_secret is not null and exists (
    select 1 from vault.decrypted_secrets d
     where d.name = 'cavscope_browser_worker_secret'
       and encode(extensions.digest(d.decrypted_secret, 'sha256'), 'hex') = encode(extensions.digest(p_secret, 'sha256'), 'hex'))
$$;
revoke all on function cavscope.worker_secret_ok(text) from public, anon, authenticated;

create or replace function public.cavscope_worker_claim_browser(p_secret text, p_scan_id bigint default null, p_limit integer default 1)
returns setof jsonb
language plpgsql security definer set search_path to ''
as $$
begin
  if not cavscope.worker_secret_ok(p_secret) then raise exception 'forbidden' using errcode = '42501'; end if;
  return query select * from cavscope.engine_claim_browser(p_scan_id, least(greatest(coalesce(p_limit, 1), 1), 3));
end;
$$;

create or replace function public.cavscope_worker_ingest(p_secret text, p_scan_id bigint, p_scan jsonb, p_evidence jsonb, p_findings jsonb)
returns jsonb
language plpgsql security definer set search_path to ''
as $$
begin
  if not cavscope.worker_secret_ok(p_secret) then raise exception 'forbidden' using errcode = '42501'; end if;
  if not exists (select 1 from cavscope.scans where id = p_scan_id and engine = 'browser' and status = 'running') then
    raise exception 'scan % is not a running browser scan', p_scan_id using errcode = '22023';
  end if;
  return cavscope.engine_ingest(p_scan_id, p_scan, p_evidence, p_findings);
end;
$$;

create or replace function public.cavscope_worker_fail(p_secret text, p_scan_id bigint, p_error text)
returns void
language plpgsql security definer set search_path to ''
as $$
begin
  if not cavscope.worker_secret_ok(p_secret) then raise exception 'forbidden' using errcode = '42501'; end if;
  if not exists (select 1 from cavscope.scans where id = p_scan_id and engine = 'browser' and status = 'running') then
    raise exception 'scan % is not a running browser scan', p_scan_id using errcode = '22023';
  end if;
  perform cavscope.engine_fail(p_scan_id, left(p_error, 500));
end;
$$;

create or replace function public.cavscope_worker_open_findings(p_secret text, p_website_id bigint)
returns table (rule_id text, location text)
language plpgsql stable security definer set search_path to ''
as $$
begin
  if not cavscope.worker_secret_ok(p_secret) then raise exception 'forbidden' using errcode = '42501'; end if;
  return query
    select f.rule_id::text, f.location::text
      from cavscope.findings f join cavscope.scan_rules r on r.rule_id = f.rule_id
     where f.website_id = p_website_id and r.check_type = 'browser' and f.status in ('open', 'reopened');
end;
$$;

revoke all on function public.cavscope_worker_claim_browser(text, bigint, integer) from public;
revoke all on function public.cavscope_worker_ingest(text, bigint, jsonb, jsonb, jsonb) from public;
revoke all on function public.cavscope_worker_fail(text, bigint, text) from public;
revoke all on function public.cavscope_worker_open_findings(text, bigint) from public;
grant execute on function public.cavscope_worker_claim_browser(text, bigint, integer) to anon, authenticated, service_role;
grant execute on function public.cavscope_worker_ingest(text, bigint, jsonb, jsonb, jsonb) to anon, authenticated, service_role;
grant execute on function public.cavscope_worker_fail(text, bigint, text) to anon, authenticated, service_role;
grant execute on function public.cavscope_worker_open_findings(text, bigint) to anon, authenticated, service_role;

-- Kicking the function. Like do_request_scan's kick: if pg_net fails, the sweep below still finds the scan.
create or replace function cavscope.kick_browser_scan(p_scan_id bigint) returns void
language plpgsql security definer set search_path to ''
as $$
declare v_secret text;
begin
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'cavscope_browser_worker_secret' limit 1;
  if v_secret is null then raise exception 'no worker secret in Vault'; end if;
  perform net.http_post(
    url := 'https://cavscope.28footsystems.com/api/browser-scan',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cavscope-worker-secret', v_secret),
    body := jsonb_build_object('scan_id', p_scan_id),
    timeout_milliseconds := 10000);
end;
$$;
revoke all on function cavscope.kick_browser_scan(bigint) from public, anon, authenticated;

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

  begin
    perform cavscope.kick_browser_scan(v_scan_id);
  exception when others then
    insert into cavscope.activity_events (organization_id, entity_type, entity_id, action, detail)
    values (v_org, 'scan', v_scan_id, 'Browser engine kick deferred', left(SQLERRM, 500));
  end;

  return jsonb_build_object('scan_id', v_scan_id, 'status', 'queued', 'deduplicated', false, 'options', v_opts);
end;
$$;
revoke all on function cavscope.do_request_browser_scan(bigint, bigint, text, boolean, boolean) from public, anon, authenticated;

-- Sweep: posts to the function only when a queued browser scan has waited over two minutes (its kick never
-- arrived). With nothing stuck it does nothing, so it costs no function invocations.
create or replace function cavscope.kick_stale_browser_scans() returns integer
language plpgsql security definer set search_path to ''
as $$
declare v_id bigint; n integer := 0;
begin
  update cavscope.scans set status = 'failed', finished_at = now(),
    error_message = coalesce(error_message, 'Engine timeout: no result within 20 minutes')
   where engine = 'browser' and status = 'running' and started_at < now() - interval '20 minutes';
  for v_id in select id from cavscope.scans
               where engine = 'browser' and status = 'queued' and queued_at < now() - interval '2 minutes'
               order by queued_at limit 1 loop
    perform cavscope.kick_browser_scan(v_id);
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke all on function cavscope.kick_stale_browser_scans() from public, anon, authenticated;

select cron.schedule('cavscope-browser-sweep', '*/5 * * * *', $c$select cavscope.kick_stale_browser_scans()$c$)
 where not exists (select 1 from cron.job where jobname = 'cavscope-browser-sweep');
