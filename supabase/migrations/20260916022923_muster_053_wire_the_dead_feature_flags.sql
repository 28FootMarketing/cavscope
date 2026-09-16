-- muster_053: make four declared flags actually do something.
--
-- muster_052 recorded, per flag, where it is enforced. This one changes four of
-- those answers from "nowhere" to a real call site. All four default ON, so no
-- behaviour changes until someone turns one off -- the point is that turning one
-- off now has an effect.
--
--   scheduled_scans        -> muster.engine_claim's due-scan CTE
--   email_alerts           -> public.muster_engine_claim_alerts
--   support_impersonation  -> public.muster_admin_impersonate_start
--   admin_url_scanner      -> public.muster_admin_run_url
--
-- Also adds muster.flag_state_for_org(), which is has_flag() minus the
-- per-user override step. has_flag consults the CALLING user's overrides first,
-- which is right for a tenant asking "can I do this" and wrong for two other
-- jobs: an engine path running as service_role where there is no user at all,
-- and the console asking "what does org 17 resolve to" -- an answer that must
-- not depend on whose session is asking.

create or replace function muster.flag_state_for_org(p_org bigint, p_key text)
 returns boolean
 language plpgsql
 stable security definer
 set search_path to ''
as $function$
declare
  f muster.feature_flags%rowtype;
  v_ov boolean;
  v_plan_rank integer;
  v_min_rank integer;
begin
  select * into f from muster.feature_flags where key = p_key;
  if not found then return false; end if;
  if f.kill_switch then return false; end if;

  if p_org is not null then
    select enabled into v_ov from muster.feature_flag_overrides
    where flag_key = p_key and organization_id = p_org and user_id is null
      and (expires_at is null or expires_at > now());
    if found then return v_ov; end if;

    if f.plan_minimum is not null then
      select p.rank into v_plan_rank
      from muster.organizations o join muster.plans p on p.plan = o.plan where o.id = p_org;
      select rank into v_min_rank from muster.plans where plan = f.plan_minimum;
      if coalesce(v_plan_rank, -1) < coalesce(v_min_rank, 0) then return false; end if;
    end if;
  end if;
  return f.default_enabled;
end;
$function$;

comment on function muster.flag_state_for_org(bigint, text) is
  'Resolves a flag for an organization ignoring per-user overrides: kill switch, then org override, then plan minimum, then default. Use this from engine paths (no user session) and from the admin console (the answer must not depend on who is looking). Use has_flag() when answering for the calling user.';

revoke all on function muster.flag_state_for_org(bigint, text) from public, anon, authenticated;
grant execute on function muster.flag_state_for_org(bigint, text) to service_role;

-- scheduled_scans was declared and read by nothing, so turning it off left
-- pg_cron scanning anyway. The gate goes in the due-scan CTE rather than on the
-- cron schedule so it is per-organization: an org override stops cadence
-- scanning for that org alone, and the kill switch stops it for everyone.
-- next_run_at is NOT bumped for a gated website -- the bump joins `due`, which
-- the gated row never enters -- so switching the flag back on resumes on the
-- next tick instead of having silently skipped windows.
create or replace function muster.engine_claim(p_scan_id bigint DEFAULT NULL::bigint, p_limit integer DEFAULT 3)
 returns setof jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
begin
  -- Time out scans that never reported back.
  update muster.scans set status = 'failed', finished_at = now(),
    error_message = coalesce(error_message, 'Engine timeout: no result within 10 minutes')
  where status = 'running' and started_at < now() - interval '10 minutes';

  if p_scan_id is not null then
    return query
      with claimed as (
        update muster.scans s set status = 'running', started_at = now()
        where s.id = p_scan_id and s.status = 'queued'
        returning s.*
      )
      select jsonb_build_object('scan_id', c.id, 'website_id', c.website_id, 'organization_id', c.organization_id,
        'target_url', c.target_url, 'website_name', w.name, 'trigger', c.trigger,
        'max_pages', coalesce(st.max_pages, 1))
      from claimed c join muster.websites w on w.id = c.website_id
      left join muster.website_scan_settings st on st.website_id = c.website_id;
    return;
  end if;

  -- Scheduled: websites whose next_run_at is due and have nothing in flight.
  return query
    with due as (
      select st.website_id, w.organization_id, w.url, w.name, st.max_pages
      from muster.website_scan_settings st
      join muster.websites w on w.id = st.website_id
      where st.enabled and st.next_run_at <= now()
        and muster.flag_state_for_org(w.organization_id, 'scheduled_scans')
        and not exists (select 1 from muster.scans x where x.website_id = w.id and x.status in ('queued','running'))
      order by st.next_run_at
      limit p_limit
      for update of st skip locked
    ), bumped as (
      update muster.website_scan_settings st set next_run_at = now() + (st.cadence_minutes || ' minutes')::interval
      from due where st.website_id = due.website_id
      returning st.website_id
    ), created as (
      insert into muster.scans (organization_id, website_id, trigger, status, target_url, started_at)
      select d.organization_id, d.website_id, 'scheduled', 'running', d.url, now() from due d
      returning *
    )
    select jsonb_build_object('scan_id', c.id, 'website_id', c.website_id, 'organization_id', c.organization_id,
      'target_url', c.target_url, 'website_name', d.name, 'trigger', c.trigger, 'max_pages', d.max_pages)
    from created c join due d on d.website_id = c.website_id;

  -- Queued manual/api scans whose HTTP kick failed to arrive. Deliberately NOT
  -- gated on scheduled_scans: a member or an agent asked for these, and that
  -- path is manual_scans, a different flag.
  return query
    with stale as (
      update muster.scans s set status = 'running', started_at = now()
      where s.id in (
        select id from muster.scans where status = 'queued' and queued_at < now() - interval '2 minutes'
        order by queued_at limit p_limit for update skip locked)
      returning s.*
    )
    select jsonb_build_object('scan_id', c.id, 'website_id', c.website_id, 'organization_id', c.organization_id,
      'target_url', c.target_url, 'website_name', w.name, 'trigger', c.trigger,
      'max_pages', coalesce(st.max_pages, 1))
    from stale c join muster.websites w on w.id = c.website_id
    left join muster.website_scan_settings st on st.website_id = c.website_id;
end;
$function$;

revoke all on function muster.engine_claim(bigint, integer) from public, anon, authenticated;
grant execute on function muster.engine_claim(bigint, integer) to service_role;

-- email_alerts gates the CLAIM, not the enqueue, so turning it off also holds
-- alerts that are already queued. Held rows stay 'pending' -- not dropped, not
-- marked skipped -- and drain on the next 5-minute tick once it is switched
-- back on. That is the difference between a kill switch and data loss.
create or replace function public.muster_engine_claim_alerts(p_limit integer DEFAULT 20)
 returns setof muster.notification_outbox
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  r      muster.notification_outbox%rowtype;
  v_live text[];
begin
  for r in
    update muster.notification_outbox
    set status = 'sending'
    where id in (
      select id from muster.notification_outbox
      where status = 'pending'
        and muster.flag_state_for_org(organization_id, 'email_alerts')
      order by created_at
      limit p_limit
      for update skip locked
    )
    returning *
  loop
    select coalesce(array_agg(a), '{}')
      into v_live
    from unnest(r.recipient_emails) a
    where not exists (
      select 1 from muster.email_suppressions s
      where s.email = lower(btrim(a))
    );

    if coalesce(array_length(v_live, 1), 0) = 0 then
      update muster.notification_outbox
      set status = 'skipped',
          last_error = 'every recipient is suppressed (bounce or complaint)'
      where id = r.id;
      continue;
    end if;

    r.recipient_emails := v_live;
    return next r;
  end loop;
end;
$function$;

-- Engine RPCs are called only by edge functions holding the service-role key.
-- Supabase's default privileges GRANT EXECUTE on every new public function to
-- anon and authenticated, and `revoke ... from public` does not undo that --
-- PUBLIC the pseudo-role and anon/authenticated the real roles are different
-- grantees. CREATE OR REPLACE preserves the existing ACL, but the revoke is
-- named anyway so a future copy of this block cannot inherit the hole that
-- muster_050 was written to close.
revoke all on function public.muster_engine_claim_alerts(integer) from public, anon, authenticated;
grant execute on function public.muster_engine_claim_alerts(integer) to service_role;

-- support_impersonation: a platform kill switch on the most sensitive thing in
-- the console. It refuses at the start only. An open session is left to expire
-- on its own timer rather than yanked, and the append-only audit trail does not
-- consult this flag.
create or replace function public.muster_admin_impersonate_start(p_target_user_id bigint, p_reason text, p_minutes integer DEFAULT 30)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  v_admin   bigint;
  v_target  muster.users%rowtype;
  v_org     bigint;
  v_id      bigint;
  v_expires timestamptz;
begin
  if not muster.is_super_admin() then
    raise exception 'only a super admin may impersonate' using errcode = '42501';
  end if;

  if not muster.flag_state_for_org(null, 'support_impersonation') then
    raise exception 'support impersonation is switched off platform-wide (feature flag support_impersonation)'
      using errcode = '42501';
  end if;

  v_admin := muster.current_user_id();
  if v_admin is null then
    raise exception 'no MUSTER user for the calling account' using errcode = '42501';
  end if;

  if p_minutes is null or p_minutes < 1 or p_minutes > 60 then
    raise exception 'duration must be between 1 and 60 minutes' using errcode = '22023';
  end if;

  -- A reason short enough to be typed without thinking is not a reason.
  if p_reason is null or length(btrim(p_reason)) < 10 then
    raise exception 'a reason of at least 10 characters is required' using errcode = '22023';
  end if;

  select * into v_target from muster.users where id = p_target_user_id;
  if not found then
    raise exception 'no such user' using errcode = 'P0002';
  end if;

  if v_target.id = v_admin then
    raise exception 'cannot impersonate yourself' using errcode = '22023';
  end if;

  -- Blocks lateral escalation. Without this, an admin who loses their own
  -- access, or wants to act outside their own audit trail, can borrow a peer's.
  if v_target.role = 'super_admin' then
    raise exception 'cannot impersonate another super admin' using errcode = '42501';
  end if;

  if exists (
    select 1 from muster.impersonation_sessions
    where admin_user_id = v_admin and ended_at is null and expires_at > now()
  ) then
    raise exception 'you already have an active impersonation session; end it first'
      using errcode = '55006';
  end if;

  -- Close out anything expired so the partial unique index stays satisfiable.
  update muster.impersonation_sessions
  set ended_at = now(), ended_reason = 'expired'
  where admin_user_id = v_admin and ended_at is null and expires_at <= now();

  select om.organization_id into v_org
  from muster.organization_members om
  where om.user_id = v_target.id
  order by om.organization_id
  limit 1;

  v_expires := now() + make_interval(mins => p_minutes);

  insert into muster.impersonation_sessions
    (admin_user_id, target_user_id, organization_id, reason, expires_at)
  values (v_admin, v_target.id, v_org, btrim(p_reason), v_expires)
  returning id into v_id;

  insert into muster.impersonation_events (session_id, action, detail)
  values (v_id, 'session_started', jsonb_build_object('minutes', p_minutes));

  -- The tenant is not kept in the dark. This lands in the org's own activity
  -- feed, which its members can read, so impersonation is visible to the people
  -- being impersonated rather than only to us.
  if v_org is not null then
    insert into muster.activity_events (organization_id, entity_type, entity_id, action, detail, actor_id)
    values (v_org, 'user', v_target.id, 'admin_impersonation_started',
            'A MUSTER super admin opened a read-only support session for this account. Reason: ' || btrim(p_reason),
            v_admin);
  end if;

  return jsonb_build_object(
    'session_id', v_id,
    'target_user_id', v_target.id,
    'target_email', v_target.email,
    'organization_id', v_org,
    'expires_at', v_expires,
    'read_only', true
  );
end;
$function$;

revoke all on function public.muster_admin_impersonate_start(bigint, text, integer) from public, anon;
grant execute on function public.muster_admin_impersonate_start(bigint, text, integer) to authenticated, service_role;

-- admin_url_scanner: scanning an arbitrary third-party URL on demand is the one
-- thing in this console that reaches outside our own tenants. It gets its own
-- switch, separate from the tenant scan engine.
create or replace function public.muster_admin_run_url(p_url text, p_name text DEFAULT NULL::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  v_org bigint;
  v_url text := trim(coalesce(p_url, ''));
  v_website_id bigint;
  v_result jsonb;
  v_created boolean := false;
begin
  if not muster.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  if not muster.flag_state_for_org(null, 'admin_url_scanner') then
    raise exception 'the ad-hoc URL scanner is switched off (feature flag admin_url_scanner)' using errcode = '42501';
  end if;
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
$function$;

revoke all on function public.muster_admin_run_url(text, text) from public, anon;
grant execute on function public.muster_admin_run_url(text, text) to authenticated, service_role;
