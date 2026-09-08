-- muster_038: admin impersonation, with the audit protocol that makes it
-- defensible.
--
-- THE CENTRAL DECISION: there is no session swap. This does NOT mint a token
-- for the target user and does NOT change auth.uid(). The admin stays
-- themselves for the whole session.
--
-- The alternative -- generating a real session for the target -- is what most
-- products mean by "impersonate", and it is strictly worse here:
--   * it creates a genuine credential for someone else's account, which cannot
--     be distinguished from that person signing in, by RLS or by anyone
--     reading the logs afterwards;
--   * it cannot be revoked before the token expires;
--   * every write the admin makes is attributed to the tenant.
--
-- Instead: an audited, time-boxed, reason-bound session authorises super-admin
-- SECURITY DEFINER reads to return one specific user's view. Every read is
-- logged against the session. Ending the session revokes access immediately,
-- because authorisation is re-checked on every call rather than carried in a
-- token.
--
-- READ ONLY, DELIBERATELY. Nothing here can write tenant data as the target.
-- There is no "act as" write path and one must not be added: the moment an
-- admin can change a tenant's data under the tenant's name, the audit trail
-- stops being able to answer "who did this".

create table if not exists muster.impersonation_sessions (
  id                bigserial primary key,
  admin_user_id     bigint not null references muster.users(id),
  target_user_id    bigint not null references muster.users(id),
  organization_id   bigint references muster.organizations(id),
  -- Free text, and required. A reason nobody has to give is a reason nobody
  -- writes down, and the audit trail is the whole point of this feature.
  reason            text not null check (length(btrim(reason)) >= 10),
  started_at        timestamptz not null default now(),
  expires_at        timestamptz not null,
  ended_at          timestamptz,
  ended_reason      varchar(24) check (ended_reason in ('ended_by_admin','expired','revoked')),
  constraint impersonation_no_self check (admin_user_id <> target_user_id),
  constraint impersonation_bounded check (expires_at > started_at and expires_at <= started_at + interval '60 minutes')
);

-- One live session per admin. Partial unique index rather than a check, so the
-- constraint is enforced across rows: an admin cannot quietly hold two.
create unique index if not exists impersonation_one_active_per_admin
  on muster.impersonation_sessions (admin_user_id)
  where ended_at is null;

create index if not exists impersonation_sessions_target
  on muster.impersonation_sessions (target_user_id, started_at desc);

comment on table muster.impersonation_sessions is
  'Time-boxed, reason-bound super-admin sessions authorising read-only access to one user''s view. No token is ever minted for the target; auth.uid() is unchanged throughout.';

-- Append-only. Every read taken under a session lands here.
create table if not exists muster.impersonation_events (
  id           bigserial primary key,
  session_id   bigint not null references muster.impersonation_sessions(id),
  action       varchar(48) not null,
  detail       jsonb not null default '{}'::jsonb,
  occurred_at  timestamptz not null default now()
);

create index if not exists impersonation_events_session
  on muster.impersonation_events (session_id, occurred_at desc);

comment on table muster.impersonation_events is
  'Append-only log of everything done under an impersonation session. No update or delete grant exists on this table by design.';

alter table muster.impersonation_sessions enable row level security;
alter table muster.impersonation_events   enable row level security;

-- The caller's live session, or nothing. Expiry is evaluated here rather than
-- trusted from a flag, so a session that ran out mid-use stops working on the
-- very next call without anything having to sweep it.
create or replace function muster.active_impersonation()
returns muster.impersonation_sessions
language sql
stable
security definer
set search_path to ''
as $$
  select s.*
  from muster.impersonation_sessions s
  where s.admin_user_id = muster.current_user_id()
    and s.ended_at is null
    and s.expires_at > now()
  limit 1;
$$;

-- Opens a session. Every guard is here rather than in the UI, because the UI is
-- not what an attacker uses.
create or replace function public.muster_admin_impersonate_start(
  p_target_user_id bigint,
  p_reason         text,
  p_minutes        integer default 30
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
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
$$;

-- Ends the caller's session. Idempotent: ending an already-ended session is not
-- an error, because the failure mode worth avoiding is an admin believing they
-- closed one when they did not.
create or replace function public.muster_admin_impersonate_end()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare v_id bigint; v_org bigint; v_admin bigint; v_target bigint;
begin
  if not muster.is_super_admin() then
    raise exception 'only a super admin may impersonate' using errcode = '42501';
  end if;
  v_admin := muster.current_user_id();

  update muster.impersonation_sessions
  set ended_at = now(),
      ended_reason = case when expires_at <= now() then 'expired' else 'ended_by_admin' end
  where admin_user_id = v_admin and ended_at is null
  returning id, organization_id, target_user_id into v_id, v_org, v_target;

  if v_id is null then
    return jsonb_build_object('ended', false, 'reason', 'no active session');
  end if;

  insert into muster.impersonation_events (session_id, action)
  values (v_id, 'session_ended');

  if v_org is not null then
    insert into muster.activity_events (organization_id, entity_type, entity_id, action, detail, actor_id)
    values (v_org, 'user', v_target, 'admin_impersonation_ended',
            'The MUSTER support session for this account was closed.', v_admin);
  end if;

  return jsonb_build_object('ended', true, 'session_id', v_id);
end;
$$;

-- What the caller currently holds, if anything. Safe to poll; writes nothing.
create or replace function public.muster_admin_impersonate_status()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare s muster.impersonation_sessions%rowtype; u muster.users%rowtype;
begin
  if not muster.is_super_admin() then
    raise exception 'only a super admin may impersonate' using errcode = '42501';
  end if;

  s := muster.active_impersonation();
  if s.id is null then
    return jsonb_build_object('active', false);
  end if;
  select * into u from muster.users where id = s.target_user_id;

  return jsonb_build_object(
    'active', true,
    'session_id', s.id,
    'target_user_id', s.target_user_id,
    'target_email', u.email,
    'organization_id', s.organization_id,
    'reason', s.reason,
    'started_at', s.started_at,
    'expires_at', s.expires_at,
    'seconds_remaining', greatest(0, floor(extract(epoch from (s.expires_at - now())))::bigint),
    'read_only', true
  );
end;
$$;

-- The actual point of the feature: what does this user see?
--
-- Returns the target's own view -- their organizations, websites and open
-- finding counts -- and logs the access against the session. Authorisation is
-- re-derived on every call from active_impersonation(), so ending or expiring a
-- session cuts this off immediately. Nothing here writes tenant data.
create or replace function public.muster_admin_impersonated_view()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare s muster.impersonation_sessions%rowtype; v_result jsonb;
begin
  if not muster.is_super_admin() then
    raise exception 'only a super admin may impersonate' using errcode = '42501';
  end if;

  s := muster.active_impersonation();
  if s.id is null then
    raise exception 'no active impersonation session' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'session_id', s.id,
    'target_user_id', s.target_user_id,
    'as_of', now(),
    'organizations', coalesce((
      select jsonb_agg(jsonb_build_object(
        'organization_id', o.id,
        'name', o.name,
        'role', om.role,
        'websites', coalesce((
          select jsonb_agg(jsonb_build_object(
            'website_id', w.id,
            'name', w.name,
            'url', w.url,
            'posture_score', muster.posture_score(w.id),
            'open_findings', (
              select count(*) from muster.findings f
              where f.website_id = w.id and f.status in ('open','reopened')
            ),
            'open_critical_high', (
              select count(*) from muster.findings f
              where f.website_id = w.id and f.status in ('open','reopened')
                and f.severity in ('critical','high')
            )
          ) order by w.id)
          from muster.websites w where w.organization_id = o.id
        ), '[]'::jsonb)
      ) order by o.id)
      from muster.organization_members om
      join muster.organizations o on o.id = om.organization_id
      where om.user_id = s.target_user_id
    ), '[]'::jsonb)
  ) into v_result;

  insert into muster.impersonation_events (session_id, action, detail)
  values (s.id, 'viewed_workspace',
          jsonb_build_object('organizations', jsonb_array_length(v_result->'organizations')));

  return v_result;
end;
$$;

-- The audit trail, readable by super admins. This is what the feature is
-- accountable to, so it is a first-class read rather than something you go
-- digging in tables for.
create or replace function public.muster_admin_impersonation_log(p_limit integer default 50)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare v jsonb;
begin
  if not muster.is_super_admin() then
    raise exception 'only a super admin may read the impersonation log' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(x order by x.started_at desc), '[]'::jsonb) into v
  from (
    select s.id, s.started_at, s.expires_at, s.ended_at, s.ended_reason, s.reason,
           au.email as admin_email, tu.email as target_email, s.organization_id,
           (select count(*) from muster.impersonation_events e where e.session_id = s.id) as events,
           (s.ended_at is null and s.expires_at > now()) as active
    from muster.impersonation_sessions s
    join muster.users au on au.id = s.admin_user_id
    join muster.users tu on tu.id = s.target_user_id
    order by s.started_at desc
    limit least(greatest(coalesce(p_limit, 50), 1), 500)
  ) x;

  return v;
end;
$$;

-- Grants. Postgres gives EXECUTE to PUBLIC on every new function, so without
-- this an anonymous caller could reach them and rely on is_super_admin() alone.
-- Defence in depth: the role check inside is the guard, but anon should not be
-- able to call these at all.
revoke all on function muster.active_impersonation() from public;
revoke all on function public.muster_admin_impersonate_start(bigint, text, integer) from public;
revoke all on function public.muster_admin_impersonate_end() from public;
revoke all on function public.muster_admin_impersonate_status() from public;
revoke all on function public.muster_admin_impersonated_view() from public;
revoke all on function public.muster_admin_impersonation_log(integer) from public;

grant execute on function public.muster_admin_impersonate_start(bigint, text, integer) to authenticated, service_role;
grant execute on function public.muster_admin_impersonate_end() to authenticated, service_role;
grant execute on function public.muster_admin_impersonate_status() to authenticated, service_role;
grant execute on function public.muster_admin_impersonated_view() to authenticated, service_role;
grant execute on function public.muster_admin_impersonation_log(integer) to authenticated, service_role;

-- The audit tables are never written or amended by a client. Only the SECURITY
-- DEFINER functions above touch them, and none of them update or delete an
-- event row. No grant is issued here at all: RLS is on with no policies, so a
-- direct PostgREST read returns nothing even for an authenticated super admin.
revoke all on muster.impersonation_sessions from anon, authenticated;
revoke all on muster.impersonation_events   from anon, authenticated;