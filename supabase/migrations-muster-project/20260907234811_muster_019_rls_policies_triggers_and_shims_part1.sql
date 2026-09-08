-- RLS + policies + triggers + 55 of the 70 public.muster_* RPC shims, all from
-- the live catalog on mgtmqucaldkaxvxglguw.
--
-- Policies and triggers are dropped and recreated wholesale rather than added
-- to. muster_004 enabled RLS on 16 tables and named its catch-all
-- muster_app_all, where source calls it sentinel_app_all. Reconciling those
-- one by one invites a half-and-half state; starting from empty does not.
-- There is no data on this project, so dropping a policy risks nothing.
set check_function_bodies = off;

do $$
declare r record;
begin
  for r in select schemaname, tablename, policyname from pg_policies where schemaname = 'muster' loop
    execute format('drop policy %I on %I.%I', r.policyname, r.schemaname, r.tablename);
  end loop;
  for r in
    select c.relname as tbl, t.tgname
    from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'muster' and not t.tgisinternal
  loop
    execute format('drop trigger %I on muster.%I', r.tgname, r.tbl);
  end loop;
end $$;

alter table muster.activity_events enable row level security;
alter table muster.agents enable row level security;
alter table muster.api_keys enable row level security;
alter table muster.brand_profiles enable row level security;
alter table muster.change_events enable row level security;
alter table muster.commercial_pricing enable row level security;
alter table muster.control_tests enable row level security;
alter table muster.controls enable row level security;
alter table muster.countries enable row level security;
alter table muster.embedding_queue enable row level security;
alter table muster.evidence enable row level security;
alter table muster.evidence_embeddings enable row level security;
alter table muster.evidence_links enable row level security;
alter table muster.feature_flag_overrides enable row level security;
alter table muster.feature_flags enable row level security;
alter table muster.finding_embeddings enable row level security;
alter table muster.finding_evidence enable row level security;
alter table muster.findings enable row level security;
alter table muster.incidents enable row level security;
alter table muster.jurisdiction_laws enable row level security;
alter table muster.jurisdictions enable row level security;
alter table muster.notification_outbox enable row level security;
alter table muster.onboarding_steps enable row level security;
alter table muster.organization_members enable row level security;
alter table muster.organizations enable row level security;
alter table muster.pending_commercial_grants enable row level security;
alter table muster.pending_invites enable row level security;
alter table muster.plans enable row level security;
alter table muster.pricing_settings enable row level security;
alter table muster.remediation_actions enable row level security;
alter table muster.remediation_milestones enable row level security;
alter table muster.risk_appetites enable row level security;
alter table muster.risk_control_mappings enable row level security;
alter table muster.risk_exceptions enable row level security;
alter table muster.risks enable row level security;
alter table muster.scan_evidence enable row level security;
alter table muster.scan_postprocess enable row level security;
alter table muster.scan_rules enable row level security;
alter table muster.scans enable row level security;
alter table muster.sitreps enable row level security;
alter table muster.strategic_objectives enable row level security;
alter table muster.user_preferences enable row level security;
alter table muster.users enable row level security;
alter table muster.website_scan_settings enable row level security;
alter table muster.websites enable row level security;

create policy muster_activity_insert on muster.activity_events as permissive for insert to authenticated with check (muster.can_write_org(organization_id));
create policy muster_activity_select on muster.activity_events as permissive for select to authenticated using (muster.is_org_member(organization_id));
create policy sentinel_app_all on muster.activity_events as permissive for all to muster_app using (true) with check (true);
create policy muster_agents_select on muster.agents as permissive for select to authenticated using (
CASE
    WHEN (organization_id IS NULL) THEN muster.is_super_admin()
    ELSE muster.is_org_member(organization_id)
END);
create policy muster_agents_write on muster.agents as permissive for all to authenticated using (
CASE
    WHEN (organization_id IS NULL) THEN muster.is_super_admin()
    ELSE muster.is_org_executive(organization_id)
END) with check (
CASE
    WHEN (organization_id IS NULL) THEN muster.is_super_admin()
    ELSE muster.is_org_executive(organization_id)
END);
create policy muster_api_keys_select on muster.api_keys as permissive for select to authenticated using (
CASE
    WHEN (organization_id IS NULL) THEN muster.is_super_admin()
    ELSE muster.is_org_member(organization_id)
END);
create policy muster_api_keys_update on muster.api_keys as permissive for update to authenticated using (
CASE
    WHEN (organization_id IS NULL) THEN muster.is_super_admin()
    ELSE muster.is_org_executive(organization_id)
END) with check (
CASE
    WHEN (organization_id IS NULL) THEN muster.is_super_admin()
    ELSE muster.is_org_executive(organization_id)
END);
create policy muster_brand_select on muster.brand_profiles as permissive for select to authenticated using (muster.is_org_member(organization_id));
create policy muster_brand_write on muster.brand_profiles as permissive for all to authenticated using (muster.is_org_executive(organization_id)) with check (muster.is_org_executive(organization_id));
create policy change_events_org_read on muster.change_events as permissive for select to muster_app using ((organization_id IN ( SELECT m.organization_id
   FROM (muster.organization_members m
     JOIN muster.users u ON ((u.id = m.user_id)))
  WHERE (u.auth_user_id = auth.uid()))));
create policy muster_catalog_select on muster.commercial_pricing as permissive for select to authenticated using (true);
create policy muster_control_tests_select on muster.control_tests as permissive for select to authenticated using (muster.is_org_member(muster.control_org(control_id)));
create policy muster_control_tests_write on muster.control_tests as permissive for all to authenticated using (muster.can_write_org(muster.control_org(control_id))) with check (muster.can_write_org(muster.control_org(control_id)));
create policy sentinel_app_all on muster.control_tests as permissive for all to muster_app using (true) with check (true);
create policy muster_controls_select on muster.controls as permissive for select to authenticated using (muster.is_org_member(muster.website_org(website_id)));
create policy muster_controls_write on muster.controls as permissive for all to authenticated using (muster.can_write_org(muster.website_org(website_id))) with check (muster.can_write_org(muster.website_org(website_id)));
create policy sentinel_app_all on muster.controls as permissive for all to muster_app using (true) with check (true);
create policy muster_catalog_select on muster.countries as permissive for select to authenticated using (true);
create policy muster_evidence_select on muster.evidence as permissive for select to authenticated using (muster.is_org_member(muster.website_org(website_id)));
create policy muster_evidence_write on muster.evidence as permissive for all to authenticated using (muster.can_write_org(muster.website_org(website_id))) with check (muster.can_write_org(muster.website_org(website_id)));
create policy sentinel_app_all on muster.evidence as permissive for all to muster_app using (true) with check (true);
create policy "org scope" on muster.evidence_embeddings as permissive for select to public using (((organization_id = ((auth.jwt() ->> 'organization_id'::text))::bigint) OR ( SELECT (auth.role() = 'service_role'::text))));
create policy muster_evidence_links_select on muster.evidence_links as permissive for select to authenticated using (muster.is_org_member(muster.evidence_org(evidence_id)));
create policy muster_evidence_links_write on muster.evidence_links as permissive for all to authenticated using (muster.can_write_org(muster.evidence_org(evidence_id))) with check (muster.can_write_org(muster.evidence_org(evidence_id)));
create policy sentinel_app_all on muster.evidence_links as permissive for all to muster_app using (true) with check (true);
create policy muster_flag_overrides_select on muster.feature_flag_overrides as permissive for select to authenticated using ((muster.is_super_admin() OR (user_id = muster.current_user_id()) OR muster.is_org_member(organization_id)));
create policy muster_flag_overrides_write on muster.feature_flag_overrides as permissive for all to authenticated using (muster.is_super_admin()) with check (muster.is_super_admin());
create policy muster_catalog_select on muster.feature_flags as permissive for select to authenticated using (true);
create policy "org scope" on muster.finding_embeddings as permissive for select to public using (((organization_id = ((auth.jwt() ->> 'organization_id'::text))::bigint) OR ( SELECT (auth.role() = 'service_role'::text))));
create policy muster_finding_evidence_select on muster.finding_evidence as permissive for select to authenticated using ((EXISTS ( SELECT 1
   FROM muster.findings f
  WHERE ((f.id = finding_evidence.finding_id) AND muster.is_org_member(f.organization_id)))));
create policy muster_findings_select on muster.findings as permissive for select to authenticated using (muster.is_org_member(organization_id));
create policy muster_findings_update on muster.findings as permissive for update to authenticated using (muster.can_write_org(organization_id)) with check (muster.can_write_org(organization_id));
create policy muster_catalog_select on muster.jurisdiction_laws as permissive for select to authenticated using (true);
create policy muster_catalog_select on muster.jurisdictions as permissive for select to authenticated using (true);
create policy muster_members_select on muster.organization_members as permissive for select to authenticated using (muster.is_org_member(organization_id));
create policy muster_members_write on muster.organization_members as permissive for all to authenticated using (muster.is_org_executive(organization_id)) with check (muster.is_org_executive(organization_id));
create policy sentinel_app_all on muster.organization_members as permissive for all to muster_app using (true) with check (true);
create policy muster_org_select on muster.organizations as permissive for select to authenticated using (muster.is_org_member(id));
create policy muster_org_update on muster.organizations as permissive for update to authenticated using (muster.is_org_executive(id)) with check (muster.is_org_executive(id));
create policy sentinel_app_all on muster.organizations as permissive for all to muster_app using (true) with check (true);
create policy muster_invites_select on muster.pending_invites as permissive for select to authenticated using (muster.is_org_member(organization_id));
create policy muster_invites_write on muster.pending_invites as permissive for all to authenticated using (muster.is_org_executive(organization_id)) with check (muster.is_org_executive(organization_id));
create policy muster_catalog_select on muster.plans as permissive for select to authenticated using (true);
create policy muster_remediation_select on muster.remediation_actions as permissive for select to authenticated using (muster.is_org_member(COALESCE(muster.risk_org(risk_id), muster.control_org(control_id))));
create policy muster_remediation_write on muster.remediation_actions as permissive for all to authenticated using (muster.can_write_org(COALESCE(muster.risk_org(risk_id), muster.control_org(control_id)))) with check (muster.can_write_org(COALESCE(muster.risk_org(risk_id), muster.control_org(control_id))));
create policy sentinel_app_all on muster.remediation_actions as permissive for all to muster_app using (true) with check (true);
create policy muster_milestones_select on muster.remediation_milestones as permissive for select to authenticated using (muster.is_org_member(muster.remediation_org(remediation_id)));
create policy muster_milestones_write on muster.remediation_milestones as permissive for all to authenticated using (muster.can_write_org(muster.remediation_org(remediation_id))) with check (muster.can_write_org(muster.remediation_org(remediation_id)));
create policy sentinel_app_all on muster.remediation_milestones as permissive for all to muster_app using (true) with check (true);
create policy muster_risk_appetites_select on muster.risk_appetites as permissive for select to authenticated using (muster.is_org_member(organization_id));
create policy muster_risk_appetites_write on muster.risk_appetites as permissive for all to authenticated using (muster.can_write_org(organization_id)) with check (muster.can_write_org(organization_id));
create policy sentinel_app_all on muster.risk_appetites as permissive for all to muster_app using (true) with check (true);
create policy muster_risk_control_mappings_select on muster.risk_control_mappings as permissive for select to authenticated using (muster.is_org_member(muster.risk_org(risk_id)));
create policy muster_risk_control_mappings_write on muster.risk_control_mappings as permissive for all to authenticated using (muster.can_write_org(muster.risk_org(risk_id))) with check (muster.can_write_org(muster.risk_org(risk_id)));
create policy sentinel_app_all on muster.risk_control_mappings as permissive for all to muster_app using (true) with check (true);
create policy muster_risk_exceptions_select on muster.risk_exceptions as permissive for select to authenticated using (muster.is_org_member(muster.risk_org(risk_id)));
create policy muster_risk_exceptions_write on muster.risk_exceptions as permissive for all to authenticated using (muster.can_write_org(muster.risk_org(risk_id))) with check (muster.can_write_org(muster.risk_org(risk_id)));
create policy sentinel_app_all on muster.risk_exceptions as permissive for all to muster_app using (true) with check (true);
create policy muster_risks_select on muster.risks as permissive for select to authenticated using (muster.is_org_member(muster.website_org(website_id)));
create policy muster_risks_write on muster.risks as permissive for all to authenticated using (muster.can_write_org(muster.website_org(website_id))) with check (muster.can_write_org(muster.website_org(website_id)));
create policy sentinel_app_all on muster.risks as permissive for all to muster_app using (true) with check (true);
create policy muster_scan_evidence_select on muster.scan_evidence as permissive for select to authenticated using (muster.is_org_member(organization_id));
create policy muster_catalog_select on muster.scan_rules as permissive for select to authenticated using (true);
create policy muster_scans_select on muster.scans as permissive for select to authenticated using (muster.is_org_member(organization_id));
create policy muster_sitreps_select on muster.sitreps as permissive for select to authenticated using (muster.is_org_member(organization_id));
create policy muster_strategic_objectives_select on muster.strategic_objectives as permissive for select to authenticated using (muster.is_org_member(organization_id));
create policy muster_strategic_objectives_write on muster.strategic_objectives as permissive for all to authenticated using (muster.can_write_org(organization_id)) with check (muster.can_write_org(organization_id));
create policy sentinel_app_all on muster.strategic_objectives as permissive for all to muster_app using (true) with check (true);
create policy muster_prefs_all on muster.user_preferences as permissive for all to authenticated using ((user_id = muster.current_user_id())) with check ((user_id = muster.current_user_id()));
create policy muster_users_select on muster.users as permissive for select to authenticated using (((auth_user_id = ( SELECT auth.uid() AS uid)) OR muster.shares_org_with(id) OR muster.is_super_admin()));
create policy muster_users_update on muster.users as permissive for update to authenticated using ((auth_user_id = ( SELECT auth.uid() AS uid))) with check ((auth_user_id = ( SELECT auth.uid() AS uid)));
create policy sentinel_app_all on muster.users as permissive for all to muster_app using (true) with check (true);
create policy muster_scan_settings_select on muster.website_scan_settings as permissive for select to authenticated using (muster.is_org_member(muster.website_org(website_id)));
create policy muster_scan_settings_write on muster.website_scan_settings as permissive for all to authenticated using (muster.can_write_org(muster.website_org(website_id))) with check (muster.can_write_org(muster.website_org(website_id)));
create policy muster_websites_delete on muster.websites as permissive for delete to authenticated using (muster.is_org_executive(organization_id));
create policy muster_websites_insert on muster.websites as permissive for insert to authenticated with check (muster.can_write_org(organization_id));
create policy muster_websites_select on muster.websites as permissive for select to authenticated using (muster.is_org_member(organization_id));
create policy muster_websites_update on muster.websites as permissive for update to authenticated using (muster.can_write_org(organization_id)) with check (muster.can_write_org(organization_id));
create policy sentinel_app_all on muster.websites as permissive for all to muster_app using (true) with check (true);

CREATE TRIGGER agents_touch BEFORE UPDATE ON muster.agents FOR EACH ROW EXECUTE FUNCTION muster.touch_updated_at();
CREATE TRIGGER brand_profiles_touch BEFORE UPDATE ON muster.brand_profiles FOR EACH ROW EXECUTE FUNCTION muster.touch_updated_at();
CREATE TRIGGER touch_updated_at BEFORE UPDATE ON muster.control_tests FOR EACH ROW EXECUTE FUNCTION muster.touch_updated_at();
CREATE TRIGGER touch_updated_at BEFORE UPDATE ON muster.controls FOR EACH ROW EXECUTE FUNCTION muster.touch_updated_at();
CREATE TRIGGER touch_updated_at BEFORE UPDATE ON muster.evidence FOR EACH ROW EXECUTE FUNCTION muster.touch_updated_at();
CREATE TRIGGER feature_flags_touch BEFORE UPDATE ON muster.feature_flags FOR EACH ROW EXECUTE FUNCTION muster.touch_updated_at();
CREATE TRIGGER findings_touch BEFORE UPDATE ON muster.findings FOR EACH ROW EXECUTE FUNCTION muster.touch_updated_at();
CREATE TRIGGER trg_queue_finding_for_embedding AFTER INSERT ON muster.findings FOR EACH ROW EXECUTE FUNCTION muster.queue_finding_for_embedding();
CREATE TRIGGER trg_requeue_finding_for_embedding AFTER UPDATE ON muster.findings FOR EACH ROW EXECUTE FUNCTION muster.queue_finding_for_reembedding();
CREATE TRIGGER touch_updated_at BEFORE UPDATE ON muster.organizations FOR EACH ROW EXECUTE FUNCTION muster.touch_updated_at();
CREATE TRIGGER touch_updated_at BEFORE UPDATE ON muster.remediation_actions FOR EACH ROW EXECUTE FUNCTION muster.touch_updated_at();
CREATE TRIGGER touch_updated_at BEFORE UPDATE ON muster.remediation_milestones FOR EACH ROW EXECUTE FUNCTION muster.touch_updated_at();
CREATE TRIGGER touch_updated_at BEFORE UPDATE ON muster.risk_appetites FOR EACH ROW EXECUTE FUNCTION muster.touch_updated_at();
CREATE TRIGGER touch_updated_at BEFORE UPDATE ON muster.risk_exceptions FOR EACH ROW EXECUTE FUNCTION muster.touch_updated_at();
CREATE TRIGGER touch_updated_at BEFORE UPDATE ON muster.risks FOR EACH ROW EXECUTE FUNCTION muster.touch_updated_at();
CREATE TRIGGER trg_queue_evidence_for_embedding AFTER INSERT ON muster.scan_evidence FOR EACH ROW EXECUTE FUNCTION muster.queue_evidence_for_embedding();
CREATE TRIGGER trg_requeue_evidence_for_embedding AFTER UPDATE ON muster.scan_evidence FOR EACH ROW EXECUTE FUNCTION muster.queue_evidence_for_reembedding();
CREATE TRIGGER scan_rules_touch BEFORE UPDATE ON muster.scan_rules FOR EACH ROW EXECUTE FUNCTION muster.touch_updated_at();
CREATE TRIGGER scans_touch BEFORE UPDATE ON muster.scans FOR EACH ROW EXECUTE FUNCTION muster.touch_updated_at();
CREATE TRIGGER trg_onboarding_first_scan_done AFTER UPDATE ON muster.scans FOR EACH ROW EXECUTE FUNCTION muster.onboarding_first_scan_done();
CREATE TRIGGER touch_updated_at BEFORE UPDATE ON muster.strategic_objectives FOR EACH ROW EXECUTE FUNCTION muster.touch_updated_at();
CREATE TRIGGER user_preferences_touch BEFORE UPDATE ON muster.user_preferences FOR EACH ROW EXECUTE FUNCTION muster.touch_updated_at();
CREATE TRIGGER touch_updated_at BEFORE UPDATE ON muster.users FOR EACH ROW EXECUTE FUNCTION muster.touch_updated_at();
CREATE TRIGGER website_scan_settings_touch BEFORE UPDATE ON muster.website_scan_settings FOR EACH ROW EXECUTE FUNCTION muster.touch_updated_at();
CREATE TRIGGER touch_updated_at BEFORE UPDATE ON muster.websites FOR EACH ROW EXECUTE FUNCTION muster.touch_updated_at();

CREATE OR REPLACE FUNCTION public.muster_add_website(p_organization_id bigint, p_name text, p_url text, p_environment text DEFAULT 'production'::text, p_cadence_minutes integer DEFAULT 1440)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if not muster.can_write_org(p_organization_id) then raise exception 'forbidden' using errcode = '42501'; end if;
  return muster.do_add_website(p_organization_id, p_name, p_url, p_environment, p_cadence_minutes, muster.current_user_id(), 'manual');
end;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_admin_incidents(p_status text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if not muster.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(to_jsonb(i) order by i.severity desc, i.last_seen_at desc)
    from muster.incidents i where p_status is null or i.status = p_status), '[]'::jsonb);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_admin_kill_switch(p_key text, p_on boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if not muster.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  update muster.feature_flags set kill_switch = p_on where key = p_key;
  return (select to_jsonb(f) from muster.feature_flags f where f.key = p_key);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_admin_set_plan(p_organization_id bigint, p_plan text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o muster.organizations;
begin
  if not muster.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  update muster.organizations set plan = p_plan, website_limit = (select website_limit from muster.plans where plan = p_plan)
  where id = p_organization_id returning * into o;
  if o.id is null then raise exception 'organization not found' using errcode = 'P0002'; end if;
  insert into muster.activity_events (organization_id, entity_type, entity_id, action, detail, actor_id)
  values (o.id, 'organization', o.id, 'Plan changed', p_plan, muster.current_user_id());
  return to_jsonb(o);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_admin_set_pricing_stage(p_stage text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if not muster.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_stage not in ('seed', 'fruit') then raise exception 'stage must be seed or fruit' using errcode = '22023'; end if;
  update muster.pricing_settings set current_stage = p_stage, updated_at = now() where id = true;
  return public.muster_public_pricing();
end;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_admin_set_user_role(p_email text, p_role text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare u muster.users;
begin
  if not muster.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_role not in ('user','admin','super_admin') then raise exception 'invalid role' using errcode = '22023'; end if;
  update muster.users set role = p_role where lower(email) = lower(p_email) returning * into u;
  if u.id is null then raise exception 'user not found' using errcode = 'P0002'; end if;
  return to_jsonb(u);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_admin_tenant(p_organization_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if not muster.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  return muster.q_organization(p_organization_id);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_admin_update_incident(p_id bigint, p_status text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if not muster.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  update muster.incidents set status = p_status, updated_at = now(),
    closure_evidence = case when p_note is not null then coalesce(closure_evidence,'{}'::jsonb) || jsonb_build_object('note', p_note, 'at', now()) else closure_evidence end
  where id = p_id;
  return (select to_jsonb(i) from muster.incidents i where i.id = p_id);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_admin_url_runs(p_limit integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.muster_admin_website_overview(p_website_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if not muster.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  return muster.q_website_overview(p_website_id);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_brand(p_organization_id bigint, p_website_id bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if not muster.is_org_member(p_organization_id) then raise exception 'forbidden' using errcode = '42501'; end if;
  return muster.q_brand(p_organization_id, p_website_id);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_claim_invites()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare u muster.users; v_n integer := 0; inv record;
begin
  u := muster.ensure_user_from_auth();
  for inv in select * from muster.pending_invites where lower(email) = lower(u.email) and claimed_at is null loop
    insert into muster.organization_members (organization_id, user_id, role) values (inv.organization_id, u.id, inv.role)
    on conflict do nothing;
    update muster.pending_invites set claimed_at = now() where id = inv.id;
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('claimed', v_n);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_compliance_posture(p_website_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_org bigint := muster.website_org(p_website_id);
begin
  if not muster.is_org_member(v_org) then raise exception 'forbidden' using errcode = '42501'; end if;
  if not muster.has_flag(v_org, 'jurisdiction_advisor') then raise exception 'jurisdiction advisor is disabled for this organization' using errcode = '42501'; end if;
  return muster.q_compliance_posture(p_website_id);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_countries()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object('code', c.code, 'name', c.name, 'has_regions', c.has_regions,
           'has_profile', exists (select 1 from muster.jurisdictions j where j.code = c.code)) order by c.name), '[]'::jsonb)
  from muster.countries c;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_engine_agent_tools()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select muster.agent_tools();
$function$
;

CREATE OR REPLACE FUNCTION public.muster_engine_claim(p_scan_id bigint DEFAULT NULL::bigint, p_limit integer DEFAULT 3)
 RETURNS SETOF jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select muster.engine_claim(p_scan_id, p_limit);
$function$
;

CREATE OR REPLACE FUNCTION public.muster_engine_claim_alerts(p_limit integer DEFAULT 20)
 RETURNS SETOF muster.notification_outbox
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  update muster.notification_outbox
  set status = 'sending'
  where id in (
    select id from muster.notification_outbox
    where status = 'pending'
    order by created_at
    limit p_limit
    for update skip locked
  )
  returning *;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_engine_cron_health_check()
 RETURNS TABLE(jobname text, failure_count bigint, missed boolean)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  with recent as (
    select d.jobid,
           count(*) filter (
             where d.status <> 'succeeded'
               and d.start_time > now() - interval '20 minutes'
           ) as failures,
           count(*) filter (where d.status = 'succeeded') as successes
    from cron.job_run_details d
    where d.start_time > now() - interval '30 minutes'
    group by d.jobid
  )
  select j.jobname,
         coalesce(r.failures, 0)::bigint as failure_count,
         coalesce(r.successes, 0) = 0 as missed
  from cron.job j
  left join recent r on r.jobid = j.jobid
  where j.jobname like 'muster-%' and j.active;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_engine_fail(p_scan_id bigint, p_error text)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select muster.engine_fail(p_scan_id, p_error);
$function$
;

CREATE OR REPLACE FUNCTION public.muster_engine_ingest(p_scan_id bigint, p_scan jsonb, p_evidence jsonb, p_findings jsonb)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select muster.engine_ingest(p_scan_id, p_scan, p_evidence, p_findings);
$function$
;

CREATE OR REPLACE FUNCTION public.muster_engine_record_commercial_grant(p_email text, p_tier text, p_stage text, p_stripe_customer_id text, p_stripe_subscription_id text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_plan varchar;
begin
  select maps_to_plan into v_plan from muster.commercial_pricing where tier = p_tier and stage = p_stage;
  if v_plan is null then
    raise exception 'no commercial_pricing row for tier % stage %', p_tier, p_stage using errcode = '22023';
  end if;
  insert into muster.pending_commercial_grants (email, plan, stage, stripe_customer_id, stripe_subscription_id)
  values (lower(p_email), v_plan, p_stage, p_stripe_customer_id, p_stripe_subscription_id)
  on conflict (lower(email)) where applied_at is null
  do update set plan = excluded.plan, stage = excluded.stage, stripe_customer_id = excluded.stripe_customer_id,
    stripe_subscription_id = excluded.stripe_subscription_id, created_at = now();
end;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_engine_report_incident(p_fingerprint text, p_source text, p_severity text, p_affected_operation text, p_affected_release text, p_evidence jsonb)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_id bigint;
begin
  insert into muster.incidents (fingerprint, source, severity, affected_operation, affected_release, evidence)
  values (p_fingerprint, p_source, p_severity, p_affected_operation, p_affected_release, p_evidence)
  on conflict (fingerprint) where status not in ('closed','wont_fix')
  do update set occurrence_count = muster.incidents.occurrence_count + 1,
    last_seen_at = now(), evidence = excluded.evidence, updated_at = now()
  returning id into v_id;
  return v_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_engine_resolve_alert(p_id bigint, p_status text, p_error text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if p_status not in ('sent','failed') then
    raise exception 'p_status must be sent or failed' using errcode = '22023';
  end if;

  if p_status = 'sent' then
    update muster.notification_outbox
    set status = 'sent', attempts = attempts + 1, last_error = null, sent_at = now()
    where id = p_id;
  else
    -- transient failure: requeue to pending for the next dispatch cycle
    -- unless this was already the 5th attempt, in which case dead-letter.
    update muster.notification_outbox
    set attempts = attempts + 1,
        last_error = p_error,
        status = case when attempts + 1 >= 5 then 'failed' else 'pending' end
    where id = p_id;
  end if;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_engine_resolve_api_key(p_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare k muster.api_keys; a muster.agents;
begin
  select * into k from muster.api_keys where key_hash = encode(sha256(convert_to(coalesce(p_key, ''), 'utf8')), 'hex');
  if k.id is null then return null; end if;
  if k.revoked_at is not null or (k.expires_at is not null and k.expires_at < now()) then return jsonb_build_object('error', 'key revoked or expired'); end if;
  select * into a from muster.agents where id = k.agent_id;
  if not a.active then return jsonb_build_object('error', 'agent inactive'); end if;
  if k.organization_id is not null and not muster.has_flag(k.organization_id, 'agent_api') then
    return jsonb_build_object('error', 'agent API disabled for this organization');
  end if;
  update muster.api_keys set last_used_at = now() where id = k.id;
  return jsonb_build_object('key_id', k.id, 'agent_id', a.id, 'agent_name', a.name, 'kind', a.kind,
    'organization_id', k.organization_id, 'scopes', to_jsonb(k.scopes));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_engine_secret()
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select decrypted_secret from vault.decrypted_secrets where name = 'muster_cron_secret' limit 1;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_engine_sitrep(p_scan_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_id bigint; v_org bigint;
begin
  select organization_id into v_org from muster.scans where id = p_scan_id;
  if not muster.has_flag(v_org, 'sitrep_generation') then
    return jsonb_build_object('skipped', true, 'reason', 'sitrep_generation flag off');
  end if;
  v_id := muster.generate_sitrep(p_scan_id);
  return (select jsonb_build_object('sitrep_id', s.id, 'headline', s.headline, 'posture_score', s.posture_score, 'posture_band', s.posture_band)
          from muster.sitreps s where s.id = v_id);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_ensure_user()
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select to_jsonb(muster.ensure_user_from_auth());
$function$
;

CREATE OR REPLACE FUNCTION public.muster_evidence(p_evidence_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_org bigint;
begin
  select organization_id into v_org from muster.scan_evidence where id = p_evidence_id;
  if not muster.is_org_member(v_org) then raise exception 'forbidden' using errcode = '42501'; end if;
  return muster.q_evidence(p_evidence_id);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_find_auth_user_by_email(p_email text)
 RETURNS uuid
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select id from auth.users where lower(email) = lower(p_email) limit 1;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_findings(p_website_id bigint, p_statuses text[] DEFAULT ARRAY['open'::text, 'reopened'::text])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if not muster.is_org_member(muster.website_org(p_website_id)) then raise exception 'forbidden' using errcode = '42501'; end if;
  return muster.q_findings(p_website_id, p_statuses);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_flags(p_organization_id bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if p_organization_id is not null and not muster.is_org_member(p_organization_id) then raise exception 'forbidden' using errcode = '42501'; end if;
  return muster.q_flags(p_organization_id);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_ghl_webhook_secret()
 RETURNS text
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select decrypted_secret from vault.decrypted_secrets where name = 'muster_ghl_webhook_secret' limit 1;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_invite(p_organization_id bigint, p_email text, p_role text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r jsonb;
begin
  r := public.muster_invite_member(p_organization_id, p_email, p_role);
  if r->>'status' = 'pending_signup' then
    insert into muster.pending_invites (organization_id, email, role, invited_by_id)
    values (p_organization_id, lower(p_email), p_role, muster.current_user_id())
    on conflict (organization_id, email) do update set role = excluded.role, claimed_at = null;
  end if;
  return r;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_jurisdiction_advisory(p_country_code text, p_region_code text DEFAULT NULL::text, p_depth text DEFAULT 'summary'::text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select muster.q_jurisdiction_advisory(p_country_code, p_region_code, p_depth = 'full' and (select auth.uid()) is not null);
$function$
;

CREATE OR REPLACE FUNCTION public.muster_latest_sitrep(p_website_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if not muster.is_org_member(muster.website_org(p_website_id)) then raise exception 'forbidden' using errcode = '42501'; end if;
  return muster.q_latest_sitrep(p_website_id);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_mark_website_verified(p_website_id bigint)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'muster', 'public'
AS $function$ select muster.mark_website_verified(p_website_id); $function$
;

CREATE OR REPLACE FUNCTION public.muster_my_workspace()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare u muster.users;
begin
  u := muster.ensure_user_from_auth();
  return jsonb_build_object(
    'user', to_jsonb(u),
    'preferences', (select to_jsonb(pf) from muster.user_preferences pf where pf.user_id = u.id),
    'is_super_admin', u.role = 'super_admin',
    'platform_flags', muster.q_flags(null),
    'organizations', (
      select coalesce(jsonb_agg(muster.q_organization(m.organization_id) || jsonb_build_object('role', m.role) order by m.created_at), '[]'::jsonb)
      from muster.organization_members m where m.user_id = u.id));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_onboard(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare u muster.users;
begin
  if not muster.has_flag(null, 'self_serve_onboarding') then
    raise exception 'self-serve onboarding is disabled' using errcode = '42501';
  end if;
  u := muster.ensure_user_from_auth();
  return muster.do_onboard(p, u.id);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_onboarding_status()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare u muster.users; v_orgs jsonb;
begin
  u := muster.ensure_user_from_auth();
  select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'name', o.name, 'onboarding_status', o.onboarding_status, 'role', m.role,
           'websites', (select count(*) from muster.websites w where w.organization_id = o.id))), '[]'::jsonb)
  into v_orgs
  from muster.organization_members m join muster.organizations o on o.id = m.organization_id where m.user_id = u.id;
  return jsonb_build_object('user', to_jsonb(u), 'organizations', v_orgs,
    'self_serve_enabled', muster.has_flag(null, 'self_serve_onboarding'),
    'next', case when jsonb_array_length(v_orgs) = 0 then 'onboard' else 'workspace' end);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_pending_invites(p_organization_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if not muster.is_org_member(p_organization_id) then raise exception 'forbidden' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'email', i.email, 'role', i.role, 'created_at', i.created_at,
    'invited_by', (select name from muster.users where id = i.invited_by_id)) order by i.created_at desc)
    from muster.pending_invites i where i.organization_id = p_organization_id and i.claimed_at is null), '[]'::jsonb);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_plans()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce(jsonb_agg(to_jsonb(p) order by p.rank), '[]'::jsonb) from muster.plans p where p.plan <> 'internal';
$function$
;

CREATE OR REPLACE FUNCTION public.muster_promote_finding_to_risk(p_finding_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_org bigint;
begin
  select organization_id into v_org from muster.findings where id = p_finding_id;
  if not muster.can_write_org(v_org) then raise exception 'forbidden' using errcode = '42501'; end if;
  if not muster.has_flag(v_org, 'promote_finding_to_risk') then raise exception 'feature disabled' using errcode = '42501'; end if;
  return muster.do_promote_finding(p_finding_id, muster.current_user_id(), null);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_public_pricing()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select jsonb_build_object(
    'current_stage', s.current_stage,
    'muster', (select jsonb_build_object('monthly_price_cents', p.monthly_price_cents)
      from muster.commercial_pricing p where p.tier = 'muster' and p.stage = s.current_stage),
    'muster_partner', (select jsonb_build_object('monthly_price_cents', p.monthly_price_cents,
        'included_client_orgs', p.included_client_orgs, 'additional_org_price_cents', p.additional_org_price_cents)
      from muster.commercial_pricing p where p.tier = 'muster_partner' and p.stage = s.current_stage)
  )
  from muster.pricing_settings s where s.id = true;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_regions(p_country_code text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object('code', split_part(j.code, '-', 2), 'name', j.name) order by j.name), '[]'::jsonb)
  from muster.jurisdictions j where j.kind = 'region' and j.country_code = upper(p_country_code);
$function$
;

CREATE OR REPLACE FUNCTION public.muster_request_scan(p_website_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_org bigint := muster.website_org(p_website_id);
begin
  if not muster.can_write_org(v_org) then raise exception 'forbidden' using errcode = '42501'; end if;
  if not muster.has_flag(v_org, 'manual_scans') then raise exception 'manual scans are disabled for this organization' using errcode = '42501'; end if;
  return muster.do_request_scan(p_website_id, muster.current_user_id(), null, 'manual');
end;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_revoke_api_key(p_key_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare k muster.api_keys;
begin
  select * into k from muster.api_keys where id = p_key_id;
  if k.id is null then raise exception 'key not found' using errcode = 'P0002'; end if;
  if k.organization_id is null then
    if not muster.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  elsif not muster.is_org_executive(k.organization_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  update muster.api_keys set revoked_at = now() where id = p_key_id;
  return jsonb_build_object('key_id', p_key_id, 'revoked', true);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_risk_appetite(p_organization_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if not muster.is_org_member(p_organization_id) then raise exception 'forbidden' using errcode = '42501'; end if;
  return (select to_jsonb(ra) from muster.risk_appetites ra where ra.organization_id = p_organization_id);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_risks(p_website_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if not muster.is_org_member(muster.website_org(p_website_id)) then raise exception 'forbidden' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(to_jsonb(r) || jsonb_build_object(
      'owner_name', (select name from muster.users where id = r.owner_id),
      'remediation_actions', (
        select coalesce(jsonb_agg(to_jsonb(a) || jsonb_build_object('owner_name', (select name from muster.users where id = a.owner_id)) order by a.due_date nulls last), '[]'::jsonb)
        from muster.remediation_actions a where a.risk_id = r.id))
      order by case r.severity when 'critical' then 0 when 'high' then 1 when 'medium' then 2 else 3 end, r.target_date nulls last)
    from muster.risks r where r.website_id = p_website_id and r.status <> 'closed'
  ), '[]'::jsonb);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_scans(p_website_id bigint, p_limit integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if not muster.is_org_member(muster.website_org(p_website_id)) then raise exception 'forbidden' using errcode = '42501'; end if;
  return muster.q_scans(p_website_id, p_limit);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_set_org_alert_preference(p_organization_id bigint, p_enabled boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if not muster.can_write_org(p_organization_id) then raise exception 'forbidden' using errcode = '42501'; end if;
  update muster.organizations set critical_alerts_enabled = p_enabled where id = p_organization_id;
  return jsonb_build_object('organization_id', p_organization_id, 'critical_alerts_enabled', p_enabled);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_sitrep(p_sitrep_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_org bigint;
begin
  select organization_id into v_org from muster.sitreps where id = p_sitrep_id;
  if not muster.is_org_member(v_org) then raise exception 'forbidden' using errcode = '42501'; end if;
  return muster.q_sitrep(p_sitrep_id);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_sitrep_history(p_website_id bigint, p_limit integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if not muster.is_org_member(muster.website_org(p_website_id)) then raise exception 'forbidden' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', sr.id, 'version', sr.version, 'status', sr.status,
      'generated_at', sr.generated_at, 'headline', sr.headline, 'posture_score', sr.posture_score,
      'posture_band', sr.posture_band, 'scan_id', sr.scan_id) order by sr.generated_at desc)
    from (select * from muster.sitreps where website_id = p_website_id order by generated_at desc limit greatest(1, least(p_limit, 100))) sr
  ), '[]'::jsonb);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_update_finding_status(p_finding_id bigint, p_status text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_org bigint;
begin
  select organization_id into v_org from muster.findings where id = p_finding_id;
  if not muster.can_write_org(v_org) then raise exception 'forbidden' using errcode = '42501'; end if;
  return muster.do_update_finding_status(p_finding_id, p_status, p_note, muster.current_user_id(), null);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_update_scan_settings(p_website_id bigint, p_enabled boolean, p_cadence_minutes integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_org bigint := muster.website_org(p_website_id); v_min integer; st muster.website_scan_settings;
begin
  if not muster.can_write_org(v_org) then raise exception 'forbidden' using errcode = '42501'; end if;
  select p.scan_cadence_min_minutes into v_min from muster.organizations o join muster.plans p on p.plan = o.plan where o.id = v_org;
  insert into muster.website_scan_settings (website_id, enabled, cadence_minutes)
  values (p_website_id, coalesce(p_enabled, true), greatest(coalesce(p_cadence_minutes, 1440), v_min))
  on conflict (website_id) do update set enabled = excluded.enabled, cadence_minutes = excluded.cadence_minutes
  returning * into st;
  return to_jsonb(st);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.muster_website_overview(p_website_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if not muster.is_org_member(muster.website_org(p_website_id)) then raise exception 'forbidden' using errcode = '42501'; end if;
  return muster.q_website_overview(p_website_id);
end;
$function$
;
