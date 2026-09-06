-- Removes the customer-facing Seed/Fruit toggle from the public pricing page.
-- Seed/Fruit was an internal pricing-stage decision, not a software feature
-- -- it never gated entitlements (those are driven by tier alone, unchanged
-- here) -- but exposing it as a page the visitor clicks mixed an internal
-- pricing-strategy artifact into the public page. Replaces it with: exactly
-- one live price per tier shown publicly, controlled by a real super-admin
-- toggle instead of a code deploy.

-- Singleton settings row -- "id boolean primary key default true check (id)"
-- is a standard Postgres trick that makes it structurally impossible for more
-- than one row to ever exist, so "the current stage" is unambiguous.
create table if not exists muster.pricing_settings (
  id boolean primary key default true check (id),
  current_stage varchar(10) not null check (current_stage in ('seed', 'fruit')),
  updated_at timestamptz not null default now()
);

insert into muster.pricing_settings (id, current_stage) values (true, 'seed')
on conflict (id) do nothing;

alter table muster.pricing_settings enable row level security;

-- Public, anon-readable by design -- this is marketing pricing data, the
-- exact opposite of every other function added this session, which were all
-- explicitly locked to service_role. Deliberate, not an oversight.
create or replace function public.muster_public_pricing()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'current_stage', s.current_stage,
    'muster', (select jsonb_build_object('monthly_price_cents', p.monthly_price_cents)
      from muster.commercial_pricing p where p.tier = 'muster' and p.stage = s.current_stage),
    'muster_partner', (select jsonb_build_object('monthly_price_cents', p.monthly_price_cents,
        'included_client_orgs', p.included_client_orgs, 'additional_org_price_cents', p.additional_org_price_cents)
      from muster.commercial_pricing p where p.tier = 'muster_partner' and p.stage = s.current_stage)
  )
  from muster.pricing_settings s where s.id = true;
$$;
grant execute on function public.muster_public_pricing() to anon, authenticated;

-- Super-admin only, same guard as every other muster_admin_* RPC.
create or replace function public.muster_admin_set_pricing_stage(p_stage text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if not muster.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_stage not in ('seed', 'fruit') then raise exception 'stage must be seed or fruit' using errcode = '22023'; end if;
  update muster.pricing_settings set current_stage = p_stage, updated_at = now() where id = true;
  return public.muster_public_pricing();
end;
$$;
revoke all on function public.muster_admin_set_pricing_stage(text) from public, anon, authenticated;
grant execute on function public.muster_admin_set_pricing_stage(text) to authenticated;

-- Surface current pricing in the existing super-admin overview so the admin
-- panel needs no extra round trip to render the toggle.
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
    'pricing', public.muster_public_pricing());
end;
$$;
