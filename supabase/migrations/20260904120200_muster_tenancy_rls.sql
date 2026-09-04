-- MUSTER phase 1: tenancy helpers, grants, and row-level security for Supabase Auth users.
-- Project: mgtmqucaldkaxvxglguw, schema: muster
-- The legacy sentinel_app_all policies (role muster_app) are left in place; they do not
-- affect anon/authenticated/service_role. Super admins (muster.users.role = 'super_admin')
-- pass every membership check.

------------------------------------------------------------------------------
-- Identity and membership helpers (SECURITY DEFINER, initplan-wrapped auth.uid())
------------------------------------------------------------------------------
create or replace function muster.current_user_id()
returns bigint language sql stable security definer set search_path = '' as $$
  select u.id from muster.users u where u.auth_user_id = (select auth.uid());
$$;

create or replace function muster.is_super_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select u.role = 'super_admin' from muster.users u where u.auth_user_id = (select auth.uid())), false);
$$;

create or replace function muster.org_role(p_org bigint)
returns text language sql stable security definer set search_path = '' as $$
  select case when muster.is_super_admin() then 'super_admin'
         else (select m.role from muster.organization_members m
               join muster.users u on u.id = m.user_id
               where m.organization_id = p_org and u.auth_user_id = (select auth.uid())
               order by case m.role when 'executive' then 1 when 'risk_owner' then 2 when 'control_owner' then 3 when 'contributor' then 4 else 5 end
               limit 1) end;
$$;

create or replace function muster.is_org_member(p_org bigint)
returns boolean language sql stable security definer set search_path = '' as $$
  select p_org is not null and muster.org_role(p_org) is not null;
$$;

create or replace function muster.can_write_org(p_org bigint)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce(muster.org_role(p_org) in ('super_admin','executive','risk_owner','control_owner','contributor'), false);
$$;

create or replace function muster.is_org_executive(p_org bigint)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce(muster.org_role(p_org) in ('super_admin','executive'), false);
$$;

create or replace function muster.shares_org_with(p_user_id bigint)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from muster.organization_members a
    join muster.users me on me.id = a.user_id and me.auth_user_id = (select auth.uid())
    join muster.organization_members b on b.organization_id = a.organization_id
    where b.user_id = p_user_id);
$$;

create or replace function muster.website_org(p_website_id bigint)
returns bigint language sql stable security definer set search_path = '' as $$
  select organization_id from muster.websites where id = p_website_id;
$$;
create or replace function muster.risk_org(p_risk_id bigint)
returns bigint language sql stable security definer set search_path = '' as $$
  select w.organization_id from muster.risks r join muster.websites w on w.id = r.website_id where r.id = p_risk_id;
$$;
create or replace function muster.control_org(p_control_id bigint)
returns bigint language sql stable security definer set search_path = '' as $$
  select w.organization_id from muster.controls c join muster.websites w on w.id = c.website_id where c.id = p_control_id;
$$;
create or replace function muster.evidence_org(p_evidence_id bigint)
returns bigint language sql stable security definer set search_path = '' as $$
  select w.organization_id from muster.evidence e join muster.websites w on w.id = e.website_id where e.id = p_evidence_id;
$$;
create or replace function muster.remediation_org(p_remediation_id bigint)
returns bigint language sql stable security definer set search_path = '' as $$
  select coalesce(muster.risk_org(a.risk_id), muster.control_org(a.control_id))
  from muster.remediation_actions a where a.id = p_remediation_id;
$$;

-- Feature flag resolution: kill switch > user override > org override > plan gate > default.
create or replace function muster.has_flag(p_org bigint, p_key text)
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare
  f    muster.feature_flags%rowtype;
  v_uid bigint := muster.current_user_id();
  v_ov  boolean;
  v_plan_rank integer;
  v_min_rank integer;
begin
  select * into f from muster.feature_flags where key = p_key;
  if not found then return false; end if;
  if f.kill_switch then return false; end if;

  if v_uid is not null then
    select enabled into v_ov from muster.feature_flag_overrides
    where flag_key = p_key and user_id = v_uid and (expires_at is null or expires_at > now());
    if found then return v_ov; end if;
  end if;
  if p_org is not null then
    select enabled into v_ov from muster.feature_flag_overrides
    where flag_key = p_key and organization_id = p_org and user_id is null and (expires_at is null or expires_at > now());
    if found then return v_ov; end if;
    if f.plan_minimum is not null then
      select p.rank into v_plan_rank from muster.organizations o join muster.plans p on p.plan = o.plan where o.id = p_org;
      select rank into v_min_rank from muster.plans where plan = f.plan_minimum;
      if coalesce(v_plan_rank, -1) < coalesce(v_min_rank, 0) then return false; end if;
    end if;
  end if;
  return f.default_enabled;
end;
$$;

------------------------------------------------------------------------------
-- Grants
------------------------------------------------------------------------------
grant usage on schema muster to authenticated, service_role;
grant select, insert, update, delete on all tables in schema muster to service_role;
grant usage, select on all sequences in schema muster to authenticated, service_role;
grant select on all tables in schema muster to authenticated;
revoke select on muster.api_keys from authenticated;
grant select (id, agent_id, organization_id, name, key_prefix, scopes, created_by_id, last_used_at, expires_at, revoked_at, created_at)
  on muster.api_keys to authenticated;

grant insert, update on
  muster.organizations, muster.users, muster.organization_members, muster.websites, muster.risks, muster.controls,
  muster.evidence, muster.evidence_links, muster.remediation_actions, muster.remediation_milestones, muster.risk_appetites,
  muster.risk_control_mappings, muster.risk_exceptions, muster.strategic_objectives, muster.control_tests,
  muster.website_scan_settings, muster.brand_profiles, muster.user_preferences, muster.agents
  to authenticated;
grant insert on muster.activity_events to authenticated;
grant update (status, status_note, status_changed_by_id, risk_id) on muster.findings to authenticated;
grant update (revoked_at, name) on muster.api_keys to authenticated;
grant delete on
  muster.organization_members, muster.evidence_links, muster.risk_control_mappings, muster.remediation_milestones,
  muster.brand_profiles, muster.website_scan_settings, muster.websites
  to authenticated;

alter default privileges for role postgres in schema muster grant select on tables to authenticated;
alter default privileges for role postgres in schema muster grant all on tables to service_role;
alter default privileges for role postgres in schema muster grant usage, select on sequences to authenticated, service_role;

-- Function execution: helpers to authenticated + service_role; engine to service_role only.
revoke execute on all functions in schema muster from public, anon;
grant execute on function
  muster.current_user_id(), muster.is_super_admin(), muster.org_role(bigint), muster.is_org_member(bigint),
  muster.can_write_org(bigint), muster.is_org_executive(bigint), muster.shares_org_with(bigint),
  muster.website_org(bigint), muster.risk_org(bigint), muster.control_org(bigint), muster.evidence_org(bigint),
  muster.remediation_org(bigint), muster.has_flag(bigint, text), muster.posture_score(bigint), muster.posture_band(integer),
  muster.severity_weight(text), muster.severity_rank(text), muster.finding_fingerprint(bigint, text, text, text)
  to authenticated, service_role;
revoke execute on function muster.engine_claim(bigint, integer), muster.engine_fail(bigint, text),
  muster.engine_ingest(bigint, jsonb, jsonb, jsonb), muster.generate_sitrep(bigint) from authenticated;
grant execute on function muster.engine_claim(bigint, integer), muster.engine_fail(bigint, text),
  muster.engine_ingest(bigint, jsonb, jsonb, jsonb), muster.generate_sitrep(bigint) to service_role;

------------------------------------------------------------------------------
-- Row-level security
------------------------------------------------------------------------------
alter table muster.scan_rules enable row level security;
alter table muster.website_scan_settings enable row level security;
alter table muster.scans enable row level security;
alter table muster.scan_evidence enable row level security;
alter table muster.findings enable row level security;
alter table muster.finding_evidence enable row level security;
alter table muster.sitreps enable row level security;
alter table muster.plans enable row level security;
alter table muster.countries enable row level security;
alter table muster.jurisdictions enable row level security;
alter table muster.jurisdiction_laws enable row level security;
alter table muster.brand_profiles enable row level security;
alter table muster.user_preferences enable row level security;
alter table muster.feature_flags enable row level security;
alter table muster.feature_flag_overrides enable row level security;
alter table muster.agents enable row level security;
alter table muster.api_keys enable row level security;

-- Catalog tables: readable by any signed-in user.
do $$
declare t text;
begin
  foreach t in array array['scan_rules','plans','countries','jurisdictions','jurisdiction_laws','feature_flags'] loop
    execute format('drop policy if exists muster_catalog_select on muster.%I', t);
    execute format('create policy muster_catalog_select on muster.%I for select to authenticated using (true)', t);
  end loop;
end $$;

-- organizations
drop policy if exists muster_org_select on muster.organizations;
create policy muster_org_select on muster.organizations for select to authenticated
  using (muster.is_org_member(id));
drop policy if exists muster_org_update on muster.organizations;
create policy muster_org_update on muster.organizations for update to authenticated
  using (muster.is_org_executive(id)) with check (muster.is_org_executive(id));

-- users
drop policy if exists muster_users_select on muster.users;
create policy muster_users_select on muster.users for select to authenticated
  using (auth_user_id = (select auth.uid()) or muster.shares_org_with(id) or muster.is_super_admin());
drop policy if exists muster_users_update on muster.users;
create policy muster_users_update on muster.users for update to authenticated
  using (auth_user_id = (select auth.uid())) with check (auth_user_id = (select auth.uid()));

-- organization_members
drop policy if exists muster_members_select on muster.organization_members;
create policy muster_members_select on muster.organization_members for select to authenticated
  using (muster.is_org_member(organization_id));
drop policy if exists muster_members_write on muster.organization_members;
create policy muster_members_write on muster.organization_members for all to authenticated
  using (muster.is_org_executive(organization_id)) with check (muster.is_org_executive(organization_id));

-- websites
drop policy if exists muster_websites_select on muster.websites;
create policy muster_websites_select on muster.websites for select to authenticated
  using (muster.is_org_member(organization_id));
drop policy if exists muster_websites_insert on muster.websites;
create policy muster_websites_insert on muster.websites for insert to authenticated
  with check (muster.can_write_org(organization_id));
drop policy if exists muster_websites_update on muster.websites;
create policy muster_websites_update on muster.websites for update to authenticated
  using (muster.can_write_org(organization_id)) with check (muster.can_write_org(organization_id));
drop policy if exists muster_websites_delete on muster.websites;
create policy muster_websites_delete on muster.websites for delete to authenticated
  using (muster.is_org_executive(organization_id));

-- website-scoped registers: risks, controls, evidence
do $$
declare t text;
begin
  foreach t in array array['risks','controls','evidence'] loop
    execute format('drop policy if exists muster_%s_select on muster.%I', t, t);
    execute format('create policy muster_%s_select on muster.%I for select to authenticated using (muster.is_org_member(muster.website_org(website_id)))', t, t);
    execute format('drop policy if exists muster_%s_write on muster.%I', t, t);
    execute format('create policy muster_%s_write on muster.%I for all to authenticated using (muster.can_write_org(muster.website_org(website_id))) with check (muster.can_write_org(muster.website_org(website_id)))', t, t);
  end loop;
end $$;

-- evidence_links
drop policy if exists muster_evidence_links_select on muster.evidence_links;
create policy muster_evidence_links_select on muster.evidence_links for select to authenticated
  using (muster.is_org_member(muster.evidence_org(evidence_id)));
drop policy if exists muster_evidence_links_write on muster.evidence_links;
create policy muster_evidence_links_write on muster.evidence_links for all to authenticated
  using (muster.can_write_org(muster.evidence_org(evidence_id))) with check (muster.can_write_org(muster.evidence_org(evidence_id)));

-- remediation_actions
drop policy if exists muster_remediation_select on muster.remediation_actions;
create policy muster_remediation_select on muster.remediation_actions for select to authenticated
  using (muster.is_org_member(coalesce(muster.risk_org(risk_id), muster.control_org(control_id))));
drop policy if exists muster_remediation_write on muster.remediation_actions;
create policy muster_remediation_write on muster.remediation_actions for all to authenticated
  using (muster.can_write_org(coalesce(muster.risk_org(risk_id), muster.control_org(control_id))))
  with check (muster.can_write_org(coalesce(muster.risk_org(risk_id), muster.control_org(control_id))));

-- remediation_milestones
drop policy if exists muster_milestones_select on muster.remediation_milestones;
create policy muster_milestones_select on muster.remediation_milestones for select to authenticated
  using (muster.is_org_member(muster.remediation_org(remediation_id)));
drop policy if exists muster_milestones_write on muster.remediation_milestones;
create policy muster_milestones_write on muster.remediation_milestones for all to authenticated
  using (muster.can_write_org(muster.remediation_org(remediation_id))) with check (muster.can_write_org(muster.remediation_org(remediation_id)));

-- risk-scoped: risk_control_mappings, risk_exceptions
do $$
declare t text;
begin
  foreach t in array array['risk_control_mappings','risk_exceptions'] loop
    execute format('drop policy if exists muster_%s_select on muster.%I', t, t);
    execute format('create policy muster_%s_select on muster.%I for select to authenticated using (muster.is_org_member(muster.risk_org(risk_id)))', t, t);
    execute format('drop policy if exists muster_%s_write on muster.%I', t, t);
    execute format('create policy muster_%s_write on muster.%I for all to authenticated using (muster.can_write_org(muster.risk_org(risk_id))) with check (muster.can_write_org(muster.risk_org(risk_id)))', t, t);
  end loop;
end $$;

-- control_tests
drop policy if exists muster_control_tests_select on muster.control_tests;
create policy muster_control_tests_select on muster.control_tests for select to authenticated
  using (muster.is_org_member(muster.control_org(control_id)));
drop policy if exists muster_control_tests_write on muster.control_tests;
create policy muster_control_tests_write on muster.control_tests for all to authenticated
  using (muster.can_write_org(muster.control_org(control_id))) with check (muster.can_write_org(muster.control_org(control_id)));

-- org-scoped: risk_appetites, strategic_objectives
do $$
declare t text;
begin
  foreach t in array array['risk_appetites','strategic_objectives'] loop
    execute format('drop policy if exists muster_%s_select on muster.%I', t, t);
    execute format('create policy muster_%s_select on muster.%I for select to authenticated using (muster.is_org_member(organization_id))', t, t);
    execute format('drop policy if exists muster_%s_write on muster.%I', t, t);
    execute format('create policy muster_%s_write on muster.%I for all to authenticated using (muster.can_write_org(organization_id)) with check (muster.can_write_org(organization_id))', t, t);
  end loop;
end $$;

-- activity_events: append-only for members
drop policy if exists muster_activity_select on muster.activity_events;
create policy muster_activity_select on muster.activity_events for select to authenticated
  using (muster.is_org_member(organization_id));
drop policy if exists muster_activity_insert on muster.activity_events;
create policy muster_activity_insert on muster.activity_events for insert to authenticated
  with check (muster.can_write_org(organization_id));

-- website_scan_settings
drop policy if exists muster_scan_settings_select on muster.website_scan_settings;
create policy muster_scan_settings_select on muster.website_scan_settings for select to authenticated
  using (muster.is_org_member(muster.website_org(website_id)));
drop policy if exists muster_scan_settings_write on muster.website_scan_settings;
create policy muster_scan_settings_write on muster.website_scan_settings for all to authenticated
  using (muster.can_write_org(muster.website_org(website_id))) with check (muster.can_write_org(muster.website_org(website_id)));

-- scans, scan_evidence, finding_evidence, sitreps: read-only for members (engine writes via service_role)
do $$
declare t text;
begin
  foreach t in array array['scans','scan_evidence','sitreps','findings'] loop
    execute format('drop policy if exists muster_%s_select on muster.%I', t, t);
    execute format('create policy muster_%s_select on muster.%I for select to authenticated using (muster.is_org_member(organization_id))', t, t);
  end loop;
end $$;
drop policy if exists muster_finding_evidence_select on muster.finding_evidence;
create policy muster_finding_evidence_select on muster.finding_evidence for select to authenticated
  using (exists (select 1 from muster.findings f where f.id = finding_id and muster.is_org_member(f.organization_id)));

-- findings: status changes by writers (column grant limits the writable columns)
drop policy if exists muster_findings_update on muster.findings;
create policy muster_findings_update on muster.findings for update to authenticated
  using (muster.can_write_org(organization_id)) with check (muster.can_write_org(organization_id));

-- brand_profiles
drop policy if exists muster_brand_select on muster.brand_profiles;
create policy muster_brand_select on muster.brand_profiles for select to authenticated
  using (muster.is_org_member(organization_id));
drop policy if exists muster_brand_write on muster.brand_profiles;
create policy muster_brand_write on muster.brand_profiles for all to authenticated
  using (muster.is_org_executive(organization_id)) with check (muster.is_org_executive(organization_id));

-- user_preferences: own row
drop policy if exists muster_prefs_all on muster.user_preferences;
create policy muster_prefs_all on muster.user_preferences for all to authenticated
  using (user_id = muster.current_user_id()) with check (user_id = muster.current_user_id());

-- feature_flag_overrides: members see their org's overrides and their own; only super admins write
drop policy if exists muster_flag_overrides_select on muster.feature_flag_overrides;
create policy muster_flag_overrides_select on muster.feature_flag_overrides for select to authenticated
  using (muster.is_super_admin() or user_id = muster.current_user_id() or muster.is_org_member(organization_id));
drop policy if exists muster_flag_overrides_write on muster.feature_flag_overrides;
create policy muster_flag_overrides_write on muster.feature_flag_overrides for all to authenticated
  using (muster.is_super_admin()) with check (muster.is_super_admin());

-- agents and api_keys: members read; executives manage; platform-scoped rows are super admin only
drop policy if exists muster_agents_select on muster.agents;
create policy muster_agents_select on muster.agents for select to authenticated
  using (case when organization_id is null then muster.is_super_admin() else muster.is_org_member(organization_id) end);
drop policy if exists muster_agents_write on muster.agents;
create policy muster_agents_write on muster.agents for all to authenticated
  using (case when organization_id is null then muster.is_super_admin() else muster.is_org_executive(organization_id) end)
  with check (case when organization_id is null then muster.is_super_admin() else muster.is_org_executive(organization_id) end);
drop policy if exists muster_api_keys_select on muster.api_keys;
create policy muster_api_keys_select on muster.api_keys for select to authenticated
  using (case when organization_id is null then muster.is_super_admin() else muster.is_org_member(organization_id) end);
drop policy if exists muster_api_keys_update on muster.api_keys;
create policy muster_api_keys_update on muster.api_keys for update to authenticated
  using (case when organization_id is null then muster.is_super_admin() else muster.is_org_executive(organization_id) end)
  with check (case when organization_id is null then muster.is_super_admin() else muster.is_org_executive(organization_id) end);

