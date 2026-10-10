-- Support Access wiring pass (admin.html).
--
-- 1. A user can belong to several organizations and the support view shows all of them, but
--    cavscope_admin_impersonate_start told only the lowest-numbered one, so every other
--    tenant's data was read with no notice in its own feed. Start and end now write the notice
--    to every organization the target belongs to (cavscope.notify_impersonation_orgs).
-- 2. A session that simply ran out left the tenant's feed saying it had started and never that
--    it had stopped, and the log showed it with no end event. cavscope.close_expired_impersonations()
--    closes lapsed sessions, records session_ended and writes the closing notice; start and
--    status call it first.
-- 3. The reason is shown to the tenant verbatim, so it is capped at 500 characters.
-- Each in-place edit must apply exactly once or the migration aborts.

create or replace function pg_temp.sub(src text, old text, new text) returns text
language plpgsql as $f$
declare n int;
begin
  n := (length(src) - length(replace(src, old, ''))) / length(old);
  if n <> 1 then raise exception 'expected exactly 1 match, found % for: %', n, left(old, 80); end if;
  return replace(src, old, new);
end $f$;

-- Tell every organization the target belongs to, not just the lowest-numbered one.
create or replace function cavscope.notify_impersonation_orgs(p_target bigint, p_admin bigint, p_action text, p_detail text)
 returns void
 language sql
 security definer
 set search_path to ''
as $$
  insert into cavscope.activity_events (organization_id, entity_type, entity_id, action, detail, actor_id)
  select om.organization_id, 'user', p_target, p_action, p_detail, p_admin
  from cavscope.organization_members om
  where om.user_id = p_target;
$$;
revoke all on function cavscope.notify_impersonation_orgs(bigint, bigint, text, text) from public, anon, authenticated;

-- A session that simply runs out used to leave the tenant's feed saying it had started and never
-- that it had stopped. Any caller that reads or opens sessions now closes the lapsed ones first.
create or replace function cavscope.close_expired_impersonations()
 returns integer
 language plpgsql
 security definer
 set search_path to ''
as $$
declare r record; n integer := 0;
begin
  for r in
    update cavscope.impersonation_sessions
       set ended_at = now(), ended_reason = 'expired'
     where ended_at is null and expires_at <= now()
    returning id, admin_user_id, target_user_id
  loop
    insert into cavscope.impersonation_events (session_id, action) values (r.id, 'session_ended');
    perform cavscope.notify_impersonation_orgs(r.target_user_id, r.admin_user_id, 'admin_impersonation_ended',
      'The CavScope support session for this account ran out of time and closed.');
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke all on function cavscope.close_expired_impersonations() from public, anon, authenticated;

do $mig$
declare d text;
begin
  -- start
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'cavscope_admin_impersonate_start';
  d := pg_temp.sub(d, '  if p_reason is null or length(btrim(p_reason)) < 10 then',
    '  if p_reason is not null and length(btrim(p_reason)) > 500 then
    raise exception ''the reason must be 500 characters or fewer'' using errcode = ''22023'';
  end if;
  if p_reason is null or length(btrim(p_reason)) < 10 then');
  d := pg_temp.sub(d, '  update cavscope.impersonation_sessions
  set ended_at = now(), ended_reason = ''expired''
  where admin_user_id = v_admin and ended_at is null and expires_at <= now();',
    '  perform cavscope.close_expired_impersonations();');
  d := pg_temp.sub(d, '  if v_org is not null then
    insert into cavscope.activity_events (organization_id, entity_type, entity_id, action, detail, actor_id)
    values (v_org, ''user'', v_target.id, ''admin_impersonation_started'',
            ''A CavScope super admin opened a read-only support session for this account. Reason: '' || btrim(p_reason),
            v_admin);
  end if;',
    '  perform cavscope.notify_impersonation_orgs(v_target.id, v_admin, ''admin_impersonation_started'',
    ''A CavScope super admin opened a read-only support session for this account. Reason: '' || btrim(p_reason));');
  execute d;

  -- end
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'cavscope_admin_impersonate_end';
  d := pg_temp.sub(d, '  if v_org is not null then
    insert into cavscope.activity_events (organization_id, entity_type, entity_id, action, detail, actor_id)
    values (v_org, ''user'', v_target, ''admin_impersonation_ended'',
            ''The CavScope support session for this account was closed.'', v_admin);
  end if;',
    '  perform cavscope.notify_impersonation_orgs(v_target, v_admin, ''admin_impersonation_ended'',
    ''The CavScope support session for this account was closed.'');');
  execute d;

  -- status
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'cavscope_admin_impersonate_status';
  d := pg_temp.sub(d, '  s := cavscope.active_impersonation();',
    '  perform cavscope.close_expired_impersonations();
  s := cavscope.active_impersonation();');
  execute d;
end $mig$;
