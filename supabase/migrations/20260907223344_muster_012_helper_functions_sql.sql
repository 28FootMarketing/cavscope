-- The muster.* SQL helper functions, from pg_get_functiondef on the live source.
--
-- check_function_bodies is turned off for this migration. SQL-language function
-- bodies are validated at CREATE time, and several of these reference each other
-- (org_role -> is_super_admin, can_write_org -> org_role, remediation_org ->
-- risk_org + control_org). Disabling validation removes the ordering problem
-- entirely rather than forcing a hand-sorted dependency list that would rot the
-- first time one of them gains a call.
--
-- These are the authorization spine: every RLS policy and every public.muster_*
-- RPC resolves through org_role / is_org_member / can_write_org /
-- is_super_admin. They have to exist before the policies that reference them,
-- which is why functions come before RLS in this migration order.

set check_function_bodies = off;

create or replace function muster.current_user_id() returns bigint
 language sql stable security definer set search_path to '' as $function$
  select u.id from muster.users u where u.auth_user_id = (select auth.uid());
$function$;

create or replace function muster.is_super_admin() returns boolean
 language sql stable security definer set search_path to '' as $function$
  select coalesce((select u.role = 'super_admin' from muster.users u where u.auth_user_id = (select auth.uid())), false);
$function$;

create or replace function muster.org_role(p_org bigint) returns text
 language sql stable security definer set search_path to '' as $function$
  select case when muster.is_super_admin() then 'super_admin'
         else (select m.role from muster.organization_members m
               join muster.users u on u.id = m.user_id
               where m.organization_id = p_org and u.auth_user_id = (select auth.uid())
               order by case m.role when 'executive' then 1 when 'risk_owner' then 2 when 'control_owner' then 3 when 'contributor' then 4 else 5 end
               limit 1) end;
$function$;

create or replace function muster.is_org_member(p_org bigint) returns boolean
 language sql stable security definer set search_path to '' as $function$
  select p_org is not null and muster.org_role(p_org) is not null;
$function$;

create or replace function muster.is_org_executive(p_org bigint) returns boolean
 language sql stable security definer set search_path to '' as $function$
  select coalesce(muster.org_role(p_org) in ('super_admin','executive'), false);
$function$;

create or replace function muster.can_write_org(p_org bigint) returns boolean
 language sql stable security definer set search_path to '' as $function$
  select coalesce(muster.org_role(p_org) in ('super_admin','executive','risk_owner','control_owner','contributor'), false);
$function$;

create or replace function muster.shares_org_with(p_user_id bigint) returns boolean
 language sql stable security definer set search_path to '' as $function$
  select exists (
    select 1 from muster.organization_members a
    join muster.users me on me.id = a.user_id and me.auth_user_id = (select auth.uid())
    join muster.organization_members b on b.organization_id = a.organization_id
    where b.user_id = p_user_id);
$function$;

create or replace function muster.website_org(p_website_id bigint) returns bigint
 language sql stable security definer set search_path to '' as $function$
  select organization_id from muster.websites where id = p_website_id;
$function$;

create or replace function muster.control_org(p_control_id bigint) returns bigint
 language sql stable security definer set search_path to '' as $function$
  select w.organization_id from muster.controls c join muster.websites w on w.id = c.website_id where c.id = p_control_id;
$function$;

create or replace function muster.risk_org(p_risk_id bigint) returns bigint
 language sql stable security definer set search_path to '' as $function$
  select w.organization_id from muster.risks r join muster.websites w on w.id = r.website_id where r.id = p_risk_id;
$function$;

create or replace function muster.evidence_org(p_evidence_id bigint) returns bigint
 language sql stable security definer set search_path to '' as $function$
  select w.organization_id from muster.evidence e join muster.websites w on w.id = e.website_id where e.id = p_evidence_id;
$function$;

create or replace function muster.remediation_org(p_remediation_id bigint) returns bigint
 language sql stable security definer set search_path to '' as $function$
  select coalesce(muster.risk_org(a.risk_id), muster.control_org(a.control_id))
  from muster.remediation_actions a where a.id = p_remediation_id;
$function$;

create or replace function muster.count_managed_orgs(p_partner_org_id bigint) returns integer
 language sql stable security definer set search_path to '' as $function$
  select count(*)::integer from muster.organizations where managed_by_org_id = p_partner_org_id;
$function$;

create or replace function muster.severity_weight(p_severity text) returns integer
 language sql immutable set search_path to '' as $function$
  select case p_severity
    when 'critical' then 25
    when 'high' then 10
    when 'medium' then 4
    when 'low' then 1
    else 0 end;
$function$;

create or replace function muster.severity_rank(p_severity text) returns integer
 language sql immutable set search_path to '' as $function$
  select case p_severity
    when 'critical' then 1 when 'high' then 2 when 'medium' then 3 when 'low' then 4 else 5 end;
$function$;

create or replace function muster.posture_score(p_website_id bigint) returns integer
 language sql stable security definer set search_path to '' as $function$
  select greatest(0, 100 - coalesce(sum(muster.severity_weight(f.severity)), 0))::integer
  from muster.findings f
  where f.website_id = p_website_id and f.status in ('open','reopened');
$function$;

create or replace function muster.posture_band(p_score integer) returns text
 language sql immutable set search_path to '' as $function$
  select case when p_score >= 85 then 'green' when p_score >= 60 then 'amber' else 'red' end;
$function$;

create or replace function muster.finding_fingerprint(p_website_id bigint, p_rule_id text, p_page_url text, p_location text)
 returns character language sql immutable set search_path to '' as $function$
  select encode(sha256(convert_to(
    p_website_id::text || '|' || p_rule_id || '|' ||
    lower(regexp_replace(coalesce(p_page_url, ''), '[#?].*$', '')) || '|' ||
    coalesce(p_location, ''), 'utf8')), 'hex')::char(64);
$function$;

create or replace function muster.engine_fail(p_scan_id bigint, p_error text) returns void
 language sql security definer set search_path to '' as $function$
  update muster.scans set status = 'failed', finished_at = now(), error_message = left(p_error, 2000)
  where id = p_scan_id;
$function$;

create or replace function muster.mark_website_verified(p_website_id bigint) returns void
 language sql security definer set search_path to 'muster' as $function$
  update muster.websites set verified_at = now() where id = p_website_id and verified_at is null;
$function$;

create or replace function muster.onboarding_caller() returns table(user_id bigint, org_id bigint)
 language sql security definer set search_path to 'muster' as $function$
  select u.id, m.organization_id
  from muster.users u join muster.organization_members m on m.user_id = u.id
  join muster.organizations o on o.id = m.organization_id
  where u.auth_user_id = auth.uid() and m.role = 'executive' and o.onboarding_status <> 'complete'
  order by o.created_at desc limit 1;
$function$;

create or replace function muster.onboarding_seed(p_org_id bigint) returns void
 language sql security definer set search_path to 'muster' as $function$
  insert into muster.onboarding_steps (organization_id, step_no, step_key, title) values
    (p_org_id, 1, 'account',       'Secure your account'),
    (p_org_id, 2, 'organization',  'Confirm your organization'),
    (p_org_id, 3, 'website',       'Verify you own the website'),
    (p_org_id, 4, 'risk_appetite', 'Set your risk appetite'),
    (p_org_id, 5, 'team',          'Name the risk owner and SITREP recipients'),
    (p_org_id, 6, 'first_scan',    'Run your first scan'),
    (p_org_id, 7, 'sitrep',        'Read your first SITREP')
  on conflict do nothing;
$function$;
