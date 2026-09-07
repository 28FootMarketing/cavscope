-- Adds the 'incidents' key to the super admin console overview.
--
-- Recovered from supabase_migrations.schema_migrations version 20260906044516
-- (name muster_admin_overview_add_incidents), which was applied to the live
-- project but had no file in this repo. 20260906044320_muster_incidents_watchdog
-- creates muster.incidents and its RPCs but never surfaces them here, so a
-- rebuild from supabase/migrations/ produced an admin console that could not
-- see a single incident.

create or replace function public.muster_admin_overview()
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if not muster.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  return jsonb_build_object(
    'tenants', (select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'name', o.name, 'plan', o.plan, 'country_code', o.country_code,
      'region_code', o.region_code, 'onboarding_status', o.onboarding_status, 'created_at', o.created_at,
      'members', (select count(*) from muster.organization_members m where m.organization_id = o.id),
      'websites', (select count(*) from muster.websites w where w.organization_id = o.id),
      'open_critical', (select count(*) from muster.findings f where f.organization_id = o.id and f.status in ('open','reopened') and f.severity = 'critical'),
      'last_scan_at', (select max(s.finished_at) from muster.scans s where s.organization_id = o.id),
      'flag_overrides', (select count(*) from muster.feature_flag_overrides fo where fo.organization_id = o.id),
      'agents', (select count(*) from muster.agents a where a.organization_id = o.id)) order by o.created_at desc), '[]'::jsonb)
      from muster.organizations o),
    'users', (select coalesce(jsonb_agg(jsonb_build_object('id', u.id, 'name', u.name, 'email', u.email, 'role', u.role,
      'last_signed_in', u.last_signed_in) order by u.created_at desc), '[]'::jsonb) from muster.users u),
    'flags', (select coalesce(jsonb_agg(to_jsonb(f) order by f.key), '[]'::jsonb) from muster.feature_flags f),
    'overrides', (select coalesce(jsonb_agg(to_jsonb(fo) order by fo.created_at desc), '[]'::jsonb) from muster.feature_flag_overrides fo),
    'platform_agents', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'kind', a.kind, 'active', a.active,
      'keys', (select coalesce(jsonb_agg(jsonb_build_object('id', k.id, 'key_prefix', k.key_prefix, 'scopes', to_jsonb(k.scopes),
        'last_used_at', k.last_used_at, 'revoked_at', k.revoked_at)), '[]'::jsonb) from muster.api_keys k where k.agent_id = a.id))), '[]'::jsonb)
      from muster.agents a where a.organization_id is null),
    'jurisdiction_review_queue', (select coalesce(jsonb_agg(jsonb_build_object('code', j.code, 'name', j.name, 'reviewed_at', j.reviewed_at,
      'laws', (select count(*) from muster.jurisdiction_laws l where l.jurisdiction_code = j.code)) order by j.reviewed_at), '[]'::jsonb)
      from muster.jurisdictions j where j.reviewed_at < current_date - interval '180 days'),
    'engine', jsonb_build_object(
      'queued', (select count(*) from muster.scans where status = 'queued'),
      'running', (select count(*) from muster.scans where status = 'running'),
      'failed_24h', (select count(*) from muster.scans where status = 'failed' and finished_at > now() - interval '24 hours'),
      'complete_24h', (select count(*) from muster.scans where status = 'complete' and finished_at > now() - interval '24 hours'),
      'cron', (select jsonb_build_object('active', j.active, 'schedule', j.schedule) from cron.job j where j.jobname = 'muster-scan-due')),
    'alerts', jsonb_build_object(
      'pending', (select count(*) from muster.notification_outbox where status = 'pending'),
      'failed_dead_letter', (select count(*) from muster.notification_outbox where status = 'failed' and attempts >= 5),
      'sent_24h', (select count(*) from muster.notification_outbox where status = 'sent' and sent_at > now() - interval '24 hours')),
    'incidents', (select coalesce(jsonb_agg(to_jsonb(i) order by i.severity desc, i.last_seen_at desc), '[]'::jsonb)
      from muster.incidents i where i.status not in ('closed','wont_fix')),
    'pricing', public.muster_public_pricing());
end;
$$;
