-- Make force_password_change mean something.
--
-- BEFORE THIS: app_metadata.force_password_change was set on
-- admin@anthonywashingtonsr.com (a super_admin) at provisioning time and NOTHING
-- READ IT. Not a page, not a policy, not a function -- a repo-wide grep for the
-- key returned zero hits outside the JWT it rides in. The account signed in on
-- the old password and went straight to the workspace. A "must change password"
-- marker that nothing checks is worse than no marker, because it reads as a
-- satisfied control to anyone auditing the account list.
--
-- WHAT THIS DOES: adds muster.password_change_required(), a predicate over the
-- caller's OWN JWT claims, and wires it into the authorization spine. A flagged
-- caller resolves to no muster user id, no super-admin, and no role in any
-- organization. Every tenant-scoped RPC and every RLS policy that routes
-- through those helpers therefore answers empty for them.
--
-- WHY THE SPINE AND NOT EVERY RPC: measured on this database, not assumed.
--   * 79 RLS policies exist in schema muster; 52 route through
--     org_role / is_org_member / is_org_executive / can_write_org /
--     is_super_admin / current_user_id / shares_org_with. Of the 27 that do
--     not, 24 are `to muster_app` (a non-browser role) and 3 are catalog reads
--     granted to `authenticated` on reference tables (countries, plans,
--     jurisdictions, scan_rules, feature_flags, commercial_pricing).
--   * Of the public.muster_* functions executable by `authenticated`, exactly
--     five do not route through the spine: muster_countries, muster_plans,
--     muster_regions, muster_public_pricing, muster_jurisdiction_advisory.
--     All five return public reference data and no tenant row.
-- So gating the spine gates every path to tenant data that a browser has.
--
-- muster_jurisdiction_advisory is DELIBERATELY not gated. It uses auth.uid()
-- only to choose summary versus full depth on published legal reference text.
-- A flagged user seeing the summary depth is not a leak, and adding a gate
-- there would buy nothing but a branch to maintain.
--
-- THE FLAG CANNOT BE CLEARED FROM A BROWSER, WHICH IS THE POINT. app_metadata
-- is service-role-only, so clearing it needs the edge function
-- `muster-set-password`, which sets the new password and clears the flag in ONE
-- admin call or neither. A separate "clear the flag" endpoint would have been a
-- bypass with extra steps.
--
-- SERVICE ROLE IS EXEMPT BY CONSTRUCTION, not by an exception clause: a
-- service-role JWT carries no app_metadata, so the predicate is already false
-- for it. Engine functions, cron jobs and edge functions are unaffected. An
-- edge function that forwards a USER's Authorization header (muster-verify-site
-- does) is correctly subject to the gate.
--
-- CLAIMS ARE MINTED AT SIGN-IN, NOT READ LIVE. After the flag clears in the
-- database, the caller's existing access token still says true until it is
-- refreshed. The browser calls refreshSession() immediately after a successful
-- change; without that step the gate keeps answering empty and it looks like
-- the change did not take. If a user ever reports exactly that, the answer is
-- sign out and back in, not a database change.
--
-- BREAK-GLASS. This gate can lock a super admin out of the workspace -- that is
-- its job, and admin@anthonywashingtonsr.com is flagged right now. It cannot
-- lock anyone out of the Supabase dashboard. One statement undoes it for an
-- account, from the SQL editor or the MCP:
--
--   update auth.users
--      set raw_app_meta_data = raw_app_meta_data - 'force_password_change'
--    where email = 'someone@example.com';
--
-- The user must then sign out and back in, for the same claims-are-minted
-- reason above.
--
-- The predicate accepts a JSON boolean true and the strings 'true'/'t'/'1',
-- because provisioning tools write both and a gate that misses half of them is
-- not a gate. Verified against all six claim shapes (boolean true, string
-- "true", boolean false, key absent, no app_metadata, empty claims) before this
-- migration was written.

set check_function_bodies = off;

create or replace function muster.password_change_required() returns boolean
 language sql stable security definer set search_path to '' as $function$
  -- ->> renders a JSON boolean true as the text 'true', so one comparison
  -- covers both shapes. Deliberately not ::boolean: app_metadata is
  -- service-role-writable and a stray value would raise a cast error inside
  -- every RLS policy on the database, which is a far worse outcome than
  -- treating an unrecognised value as "not required".
  select coalesce(((select auth.jwt()) -> 'app_metadata' ->> 'force_password_change'), '')
         in ('true', 't', '1');
$function$;

comment on function muster.password_change_required() is
  'True when the caller''s JWT carries app_metadata.force_password_change. Gates the authorization spine: see migration muster_052 header. Cleared only by the muster-set-password edge function, which sets a new password in the same admin call.';

revoke all on function muster.password_change_required() from public;
grant execute on function muster.password_change_required() to authenticated, service_role;

-- ---- the spine ------------------------------------------------------------
-- Each of these keeps its original body verbatim; the gate is a branch in
-- front of it, so a future reader can diff against migration 012 and see
-- exactly one change per function.

create or replace function muster.current_user_id() returns bigint
 language sql stable security definer set search_path to '' as $function$
  select case when muster.password_change_required() then null::bigint
         else (select u.id from muster.users u where u.auth_user_id = (select auth.uid())) end;
$function$;

create or replace function muster.is_super_admin() returns boolean
 language sql stable security definer set search_path to '' as $function$
  select (not muster.password_change_required())
     and coalesce((select u.role = 'super_admin' from muster.users u where u.auth_user_id = (select auth.uid())), false);
$function$;

create or replace function muster.org_role(p_org bigint) returns text
 language sql stable security definer set search_path to '' as $function$
  select case when muster.password_change_required() then null::text
         when muster.is_super_admin() then 'super_admin'
         else (select m.role from muster.organization_members m
               join muster.users u on u.id = m.user_id
               where m.organization_id = p_org and u.auth_user_id = (select auth.uid())
               order by case m.role when 'executive' then 1 when 'risk_owner' then 2 when 'control_owner' then 3 when 'contributor' then 4 else 5 end
               limit 1) end;
$function$;

create or replace function muster.shares_org_with(p_user_id bigint) returns boolean
 language sql stable security definer set search_path to '' as $function$
  select (not muster.password_change_required()) and exists (
    select 1 from muster.organization_members a
    join muster.users me on me.id = a.user_id and me.auth_user_id = (select auth.uid())
    join muster.organization_members b on b.organization_id = a.organization_id
    where b.user_id = p_user_id);
$function$;

-- Onboarding is not a way around the gate: a flagged invitee sets their
-- password before they create an organization, not after.
create or replace function muster.onboarding_caller()
 returns table(user_id bigint, org_id bigint)
 language sql security definer set search_path to 'muster' as $function$
  select u.id, m.organization_id
  from muster.users u join muster.organization_members m on m.user_id = u.id
  join muster.organizations o on o.id = m.organization_id
  where not muster.password_change_required()
    and u.auth_user_id = auth.uid() and m.role = 'executive' and o.onboarding_status <> 'complete'
  order by o.created_at desc limit 1;
$function$;

-- The identity upsert raises rather than returning null, because its callers
-- treat a null return as "not signed in" and would say so. 'password_change_required'
-- is the greppable string a client can branch on; PostgREST surfaces 42501 as 403.
create or replace function muster.ensure_user_from_auth()
 returns muster.users
 language plpgsql security definer set search_path to ''
as $function$
declare
  v_uid uuid := (select auth.uid());
  v_email text;
  v_name text;
  v_provider text;
  u muster.users;
begin
  if v_uid is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;
  if muster.password_change_required() then
    raise exception 'password_change_required' using errcode = '42501';
  end if;
  select au.email, coalesce(au.raw_user_meta_data->>'full_name', au.raw_user_meta_data->>'name', split_part(au.email, '@', 1)),
         coalesce(au.raw_app_meta_data->>'provider', 'email')
  into v_email, v_name, v_provider
  from auth.users au where au.id = v_uid;

  insert into muster.users (auth_user_id, name, email, login_method, role, last_signed_in)
  values (v_uid, left(v_name, 120), left(v_email, 320), left(v_provider, 64), 'user', now())
  on conflict (auth_user_id) do update set
    email = excluded.email, login_method = excluded.login_method, last_signed_in = now(),
    name = coalesce(nullif(muster.users.name, ''), excluded.name)
  returning * into u;

  insert into muster.user_preferences (user_id) values (u.id) on conflict (user_id) do nothing;
  return u;
end;
$function$;
