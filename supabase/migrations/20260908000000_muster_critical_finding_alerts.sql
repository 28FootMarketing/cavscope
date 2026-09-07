-- PRD-001 (.planning/autonomy/prds/PRD-001-critical-finding-alerts.md):
-- outbound tenant alerts on newly-opened critical/high risks. Closes
-- WORKFLOW-COVERAGE T-07 -- today a tenant's only way to learn MUSTER
-- found something critical is to open the app and look.
--
-- Independent of BLOCKERS-AND-DECISIONS.md B-1 (GHL vs Stripe checkout) --
-- does not touch either checkout path.

-- Task 1: outbox table
create table muster.notification_outbox (
  id bigint generated always as identity primary key,
  organization_id bigint not null references muster.organizations(id),
  category varchar(30) not null check (category in ('risk_opened')),
  entity_type varchar(20) not null check (entity_type in ('risk')),
  entity_id bigint not null,
  severity varchar(10) not null check (severity in ('critical','high')),
  subject text not null,
  body_text text not null,
  recipient_emails text[] not null,
  status varchar(12) not null default 'pending' check (status in ('pending','sending','sent','failed','skipped')),
  attempts int not null default 0,
  last_error text,
  created_at timestamptz not null default now(),
  sent_at timestamptz
);

-- One alert per risk, ever -- prevents a second autotriage run (or a retry
-- race) from queuing a duplicate for the same risk before dispatch completes.
create unique index notification_outbox_dedupe_key
  on muster.notification_outbox (entity_type, entity_id, category);

create index notification_outbox_pending
  on muster.notification_outbox (status, created_at) where status = 'pending';

alter table muster.notification_outbox enable row level security;
-- No policies: same deny-by-default pattern as muster.pricing_settings and
-- muster.scan_postprocess. Access only via SECURITY DEFINER RPCs below.

-- Task 2: per-org opt-out, defaults to enabled (opt-out not opt-in -- an
-- opt-in default would silently under-deliver the product's own core value
-- proposition for every tenant who never finds the toggle).
alter table muster.organizations
  add column if not exists critical_alerts_enabled boolean not null default true;

-- Task 3: extend autotriage to queue an alert atomically with the risk it
-- describes, in the same transaction, same loop iteration.
create or replace function muster.autotriage()
returns jsonb language plpgsql security definer set search_path = 'muster','public' as $$
declare f record; rid bigint; opened int := 0; closed int := 0; drifted int := 0; sc record; queued int := 0;
  v_org record; v_recipients text[];
begin
  for sc in select s.id from muster.scans s left join muster.scan_postprocess p on p.scan_id = s.id
            where s.status='complete' and p.drift_done_at is null order by s.id limit 50
  loop drifted := drifted + muster.drift_detect(sc.id); end loop;

  for f in
    select fi.*, w.owner_id, w.name as website_name, w.url as website_url,
           r.category as rule_category, r.remediation, r.plain_english
    from muster.findings fi
    join muster.websites w on w.id = fi.website_id
    left join muster.scan_rules r on r.rule_id = fi.rule_id
    where fi.status in ('open','reopened') and fi.risk_id is null and fi.severity in ('critical','high','medium')
  loop
    insert into muster.risks (website_id, title, description, category, source, severity, status, inherent_score, residual_score, treatment, treatment_plan, owner_id, identified_at, target_date)
    values (f.website_id, f.title, coalesce(f.plain_english, f.detail), coalesce(f.rule_category,'governance'),
      case coalesce(f.rule_category,'') when 'privacy' then 'privacy_assessment' when 'accessibility' then 'accessibility_audit' when 'third_party' then 'vendor_assessment' else 'security_scan' end,
      f.severity, 'open',
      case f.severity when 'critical' then 20 when 'high' then 15 else 9 end,
      case f.severity when 'critical' then 20 when 'high' then 15 else 9 end,
      'mitigate', f.remediation, f.owner_id, coalesce(f.first_seen_at, now()),
      now() + case f.severity when 'critical' then interval '7 days' when 'high' then interval '30 days' else interval '90 days' end)
    returning id into rid;
    insert into muster.remediation_actions (risk_id, title, description, status, progress, owner_id, due_date, escalation_status)
    values (rid, 'Fix: ' || f.title, coalesce(f.remediation, f.detail), 'not_started', 0, f.owner_id,
      now() + case f.severity when 'critical' then interval '7 days' when 'high' then interval '30 days' else interval '90 days' end, 'none');
    update muster.findings set risk_id = rid where id = f.id;
    insert into muster.activity_events (organization_id, entity_type, entity_id, action, detail)
    values (f.organization_id, 'risk', rid, 'auto_opened', format('Opened from finding %s (%s)', f.rule_id, f.severity));
    opened := opened + 1;

    if f.severity in ('critical','high') then
      select o.* into v_org from muster.organizations o where o.id = f.organization_id;
      if v_org.critical_alerts_enabled then
        select coalesce(array_agg(distinct u.email), '{}')
          into v_recipients
          from muster.organization_members om
          join muster.users u on u.id = om.user_id
          where om.organization_id = f.organization_id
            and om.role in ('executive','risk_owner');
        if array_length(v_recipients, 1) > 0 then
          insert into muster.notification_outbox
            (organization_id, category, entity_type, entity_id, severity, subject, body_text, recipient_emails)
          values (
            f.organization_id, 'risk_opened', 'risk', rid, f.severity,
            format('[MUSTER] New %s risk on %s: %s', upper(f.severity), f.website_name, f.title),
            format(E'MUSTER opened a new %s-severity risk on %s (%s).\n\nFinding: %s\n%s\n\nRemediation: %s\n\nView full detail: https://app.muster.28footsystems.com/\n',
              f.severity, f.website_name, f.website_url, f.title, coalesce(f.plain_english, f.detail), coalesce(f.remediation, 'See dashboard for recommended remediation.')),
            v_recipients
          )
          on conflict (entity_type, entity_id, category) do nothing;
          queued := queued + 1;
        else
          insert into muster.activity_events (organization_id, entity_type, entity_id, action, detail)
          values (f.organization_id, 'risk', rid, 'alert_skipped_no_recipient',
            'No org member with role executive/risk_owner -- critical/high risk alert not queued');
        end if;
      end if;
    end if;
  end loop;

  for f in
    select fi.id, fi.risk_id, fi.organization_id from muster.findings fi join muster.risks r on r.id = fi.risk_id
    where fi.status = 'resolved' and r.status in ('open','in_progress')
  loop
    update muster.risks set status='mitigated', residual_score = least(residual_score, 4), updated_at = now() where id = f.risk_id;
    update muster.remediation_actions set status='verified', progress=100, verified_at=now(), status_update='Verified by rescan', updated_at=now()
      where risk_id = f.risk_id and status <> 'verified';
    insert into muster.activity_events (organization_id, entity_type, entity_id, action, detail)
    values (f.organization_id, 'risk', f.risk_id, 'auto_mitigated', 'Finding no longer detected by scan engine');
    closed := closed + 1;
  end loop;

  update muster.risks r set status='open', updated_at=now()
    from muster.findings fi where fi.risk_id = r.id and fi.status='reopened' and r.status in ('mitigated','closed');

  return jsonb_build_object('drift_events', drifted, 'risks_opened', opened, 'risks_mitigated', closed, 'alerts_queued', queued);
end $$;

-- Task 4 (server side): claim/resolve RPCs for muster-alert-dispatch,
-- mirroring the muster_engine_claim/muster_engine_fail naming convention
-- already used by muster-scan.
create or replace function public.muster_engine_claim_alerts(p_limit int default 20)
returns setof muster.notification_outbox
language sql security definer set search_path = '' as $$
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
$$;
revoke all on function public.muster_engine_claim_alerts(int) from public, anon, authenticated;
grant execute on function public.muster_engine_claim_alerts(int) to service_role;

create or replace function public.muster_engine_resolve_alert(p_id bigint, p_status text, p_error text default null)
returns void
language plpgsql security definer set search_path = '' as $$
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
$$;
revoke all on function public.muster_engine_resolve_alert(bigint, text, text) from public, anon, authenticated;
grant execute on function public.muster_engine_resolve_alert(bigint, text, text) to service_role;

-- Task 6: surface in the super-admin overview
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
    'pricing', public.muster_public_pricing());
end;
$$;
