-- Workspaces section of the Super Admin Console (admin.html).
--
-- The section was a "not instrumented" stub saying there is no workspace object. That is still true and
-- stays true: an organization IS the workspace, and a second table would give RLS a second thing to get
-- wrong. What the console lacked was a view of how each workspace is set up and used. Organizations shows
-- plan, sites and scores; Client Access shows entitlements. Neither shows the team, who can reach it by key,
-- whether its AI provider works, how it is branded, who is alerted, or what is missing. This function reads
-- all of that from the tables that already hold it, one object per organization.
--
-- "gaps" are plain statements of fact computed from the same rows ("2 of 2 sites are not verified"). They are
-- not a score and not a recommendation, and an organization with none has none.
-- Super admin only; anon has no execute grant. Read-only.

create or replace function public.cavscope_admin_workspaces()
 returns jsonb
 language plpgsql
 stable
 security definer
 set search_path to ''
as $function$
begin
  if not cavscope.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;

  return coalesce((
    with base as (
      select o.id, o.name, o.plan, o.is_admin_sandbox, o.onboarding_status, o.created_at,
             o.managed_by_org_id, o.partner_client_allowance, o.critical_alerts_enabled,
             o.sitrep_ready_alerts_enabled, coalesce(array_length(o.sitrep_recipients, 1), 0) as recipients,
             coalesce(o.website_limit, 0) as site_limit,
             (select count(*) from cavscope.organization_members m where m.organization_id = o.id) as members,
             (select coalesce(jsonb_object_agg(r.role, r.n), '{}'::jsonb)
                from (select m.role, count(*) as n from cavscope.organization_members m
                       where m.organization_id = o.id group by m.role) r) as by_role,
             (select count(*) from cavscope.pending_invites i
               where i.organization_id = o.id and i.claimed_at is null) as pending_invites,
             (select max(u.last_signed_in) from cavscope.organization_members m
                join cavscope.users u on u.id = m.user_id where m.organization_id = o.id) as last_member_sign_in,
             (select count(*) from cavscope.websites w where w.organization_id = o.id) as sites,
             (select count(*) from cavscope.websites w
               where w.organization_id = o.id and w.verified_at is not null) as sites_verified,
             (select count(*) from cavscope.websites w join cavscope.website_scan_settings ss on ss.website_id = w.id
               where w.organization_id = o.id and ss.enabled) as sites_scheduled,
             (select min(ss.cadence_minutes) from cavscope.websites w join cavscope.website_scan_settings ss on ss.website_id = w.id
               where w.organization_id = o.id and ss.enabled) as cadence_minutes,
             (select count(*) from cavscope.websites w
               where w.organization_id = o.id
                 and exists (select 1 from cavscope.scans s where s.website_id = w.id and s.status = 'complete')) as sites_scanned,
             (select max(s.finished_at) from cavscope.scans s
               where s.organization_id = o.id and s.status = 'complete') as last_scan_at,
             (select count(*) from cavscope.api_keys k where k.organization_id = o.id and k.revoked_at is null
                and (k.expires_at is null or k.expires_at > now())) as keys_active,
             (select count(*) from cavscope.api_keys k where k.organization_id = o.id) as keys_total,
             (select max(k.last_used_at) from cavscope.api_keys k where k.organization_id = o.id) as keys_last_used,
             (select count(*) from cavscope.agents a where a.organization_id = o.id and a.active) as agents_active,
             c.label as llm_label, c.model as llm_model, c.enabled as llm_enabled, c.last_ok_at as llm_ok_at,
             c.last_error_at as llm_error_at, left(c.last_error, 200) as llm_error,
             (c.organization_id is not null) as llm_configured,
             b.brand_name, b.custom_domain, b.hide_muster_attribution as brand_hides_cavscope,
             (b.id is not null) as brand_row,
             (select count(*) from cavscope.feature_flag_overrides f
               where f.organization_id = o.id and (f.expires_at is null or f.expires_at > now())) as overrides,
             (select max(a.created_at) from cavscope.activity_events a where a.organization_id = o.id) as last_activity_at,
             p.name as managed_by_name,
             (select count(*) from cavscope.organizations x where x.managed_by_org_id = o.id) as client_count,
             (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name) order by x.id), '[]'::jsonb)
                from (select id, name from cavscope.organizations where managed_by_org_id = o.id order by id limit 25) x) as clients
        from cavscope.organizations o
        left join cavscope.org_llm_config c on c.organization_id = o.id
        left join lateral (select * from cavscope.brand_profiles bp where bp.organization_id = o.id and bp.website_id is null
                            order by bp.id limit 1) b on true
        left join cavscope.organizations p on p.id = o.managed_by_org_id
    )
    select jsonb_agg(jsonb_build_object(
      'organization_id', x.id,
      'name', x.name,
      'plan', x.plan,
      'is_sandbox', x.is_admin_sandbox,
      'onboarding_status', x.onboarding_status,
      'created_at', x.created_at,
      'last_activity_at', x.last_activity_at,
      'managed_by', case when x.managed_by_org_id is null then null
                         else jsonb_build_object('id', x.managed_by_org_id, 'name', x.managed_by_name) end,
      'partner', jsonb_build_object('allowance', x.partner_client_allowance, 'clients_used', x.client_count, 'clients', x.clients),
      'team', jsonb_build_object('members', x.members, 'by_role', x.by_role, 'pending_invites', x.pending_invites,
                                 'last_sign_in', x.last_member_sign_in),
      'sites', jsonb_build_object('registered', x.sites, 'limit', x.site_limit, 'verified', x.sites_verified,
                                  'scheduled', x.sites_scheduled, 'scanned', x.sites_scanned,
                                  'cadence_minutes', x.cadence_minutes, 'last_scan_at', x.last_scan_at),
      'access', jsonb_build_object('keys_active', x.keys_active, 'keys_total', x.keys_total,
                                   'keys_last_used', x.keys_last_used, 'agents_active', x.agents_active),
      'ai', jsonb_build_object('configured', x.llm_configured, 'enabled', x.llm_enabled, 'label', x.llm_label,
                               'model', x.llm_model, 'last_ok_at', x.llm_ok_at, 'last_error_at', x.llm_error_at,
                               'last_error', x.llm_error),
      'brand', jsonb_build_object(
                 'mode', case when not coalesce(x.brand_row, false) then 'default'
                              when coalesce(x.brand_hides_cavscope, false) then 'white-label'
                              when coalesce(btrim(x.brand_name), '') <> '' then 'co-branded'
                              else 'default' end,
                 'name', x.brand_name, 'custom_domain', x.custom_domain),
      'alerts', jsonb_build_object('critical', x.critical_alerts_enabled, 'sitrep_ready', x.sitrep_ready_alerts_enabled,
                                   'custom_recipients', x.recipients),
      'overrides', x.overrides,
      'gaps', to_jsonb(array_remove(array[
        case when x.members = 0 then 'The workspace has no members.' end,
        case when x.onboarding_status is distinct from 'complete' then 'Onboarding is ' || coalesce(x.onboarding_status, 'unknown') || ', not complete.' end,
        case when x.sites = 0 then 'No website is registered.' end,
        case when x.site_limit > 0 and x.sites > x.site_limit then x.sites || ' sites are registered against a limit of ' || x.site_limit || '.' end,
        case when not x.is_admin_sandbox and x.sites > x.sites_verified then (x.sites - x.sites_verified) || ' of ' || x.sites || ' sites have not proven ownership.' end,
        case when x.sites > x.sites_scheduled then (x.sites - x.sites_scheduled) || ' of ' || x.sites || ' sites are not on a scan schedule.' end,
        case when x.sites > x.sites_scanned then (x.sites - x.sites_scanned) || ' of ' || x.sites || ' sites have no completed scan.' end,
        case when x.llm_error_at is not null and (x.llm_ok_at is null or x.llm_error_at > x.llm_ok_at) then 'The AI provider''s last call failed.' end,
        case when not x.critical_alerts_enabled then 'Critical-risk alert emails are off.' end
      ], null))
    ) order by x.is_admin_sandbox, x.id)
    from base x
  ), '[]'::jsonb);
end;
$function$;

revoke all on function public.cavscope_admin_workspaces() from public, anon;
grant execute on function public.cavscope_admin_workspaces() to authenticated;
