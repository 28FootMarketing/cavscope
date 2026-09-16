-- One payload for the standalone Super Admin Console (admin.html).
--
-- muster_admin_overview() already exists and stays: it backs the console panel
-- inside app.html and returns raw rosters (tenants, flags, overrides, agents).
-- This is the aggregate view the standalone console renders -- KPI headline
-- numbers, a 30-day activity series, portfolio health bands, a prioritised
-- action queue -- computed in Postgres so the browser gets figures rather than
-- a table dump to fold over.
--
-- Every number below is derived from a real table. Where a figure on the
-- console has no instrumentation behind it, this function returns an explicit
-- null plus an `instrumented: false`, and the page renders that state rather
-- than a placeholder. Two of those exist today and are named in-line:
-- API request volume (nothing counts requests) and billed revenue (nothing
-- reads Stripe's invoices, so `revenue` is plan-implied and says so).
create or replace function public.muster_admin_console()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_stage text;
begin
  if not muster.is_super_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  select current_stage into v_stage from muster.pricing_settings limit 1;

  return jsonb_build_object(
    'generated_at', now(),
    'stage', v_stage,

    -- ---- headline tiles ---------------------------------------------------
    'kpi', jsonb_build_object(
      -- The internal sandbox org (admin URL runs park there) is not a tenant
      -- and is excluded everywhere in this payload that counts organizations.
      'organizations', (select jsonb_build_object(
          'total', count(*) filter (where not o.is_admin_sandbox),
          'new_30d', count(*) filter (where not o.is_admin_sandbox and o.created_at > now() - interval '30 days'),
          'onboarding', count(*) filter (where not o.is_admin_sandbox and o.onboarding_status <> 'complete'),
          'sandbox', count(*) filter (where o.is_admin_sandbox))
        from muster.organizations o),

      'assessments', jsonb_build_object(
        'queued', (select count(*) from muster.scans where status = 'queued'),
        'running', (select count(*) from muster.scans where status = 'running'),
        'complete_24h', (select count(*) from muster.scans where status = 'complete' and finished_at > now() - interval '24 hours'),
        'failed_24h', (select count(*) from muster.scans where status = 'failed' and finished_at > now() - interval '24 hours'),
        'complete_7d', (select count(*) from muster.scans where status = 'complete' and finished_at > now() - interval '7 days')),

      -- "High risk" is critical + high, open or reopened. Anything the alert
      -- dispatcher would have emailed a tenant about.
      'high_risk', (select jsonb_build_object(
          'open', count(*),
          'critical', count(*) filter (where f.severity = 'critical'),
          'high', count(*) filter (where f.severity = 'high'),
          'orgs_affected', count(distinct f.organization_id),
          'new_24h', count(*) filter (where f.first_seen_at > now() - interval '24 hours'))
        from muster.findings f
        join muster.organizations o on o.id = f.organization_id and not o.is_admin_sandbox
        where f.status in ('open', 'reopened') and f.severity in ('critical', 'high')),

      -- Control effectiveness, not a compliance certification. `partial` is
      -- deliberately NOT counted as met: a half-implemented control is the
      -- thing an auditor asks about, so rounding it up would hide the queue.
      'compliance', (select jsonb_build_object(
          'met', count(*) filter (where c.assessment = 'met'),
          'partial', count(*) filter (where c.assessment = 'partial'),
          'not_met', count(*) filter (where c.assessment = 'not_met'),
          'unassessed', count(*) filter (where c.assessment is null),
          'total', count(*),
          'rate', case when count(*) = 0 then null
                       else round(100.0 * count(*) filter (where c.assessment = 'met') / count(*))::integer end)
        from muster.controls c
        join muster.websites w on w.id = c.website_id
        join muster.organizations o on o.id = w.organization_id and not o.is_admin_sandbox),

      -- Plan-implied MRR: what the current plan assignments price out to at
      -- each org's commercial stage. It is NOT billed revenue -- nothing here
      -- reads Stripe invoices, so a cancelled subscription still counts until
      -- someone changes the plan (customer.subscription.deleted is unhandled).
      'revenue', (select jsonb_build_object(
          'basis', 'plan_implied',
          'billed', false,
          'mrr_cents', coalesce(sum(cp.monthly_price_cents), 0),
          'paying_orgs', count(cp.tier),
          'unpriced_orgs', count(*) filter (where cp.tier is null))
        from muster.organizations o
        left join muster.commercial_pricing cp
          on cp.maps_to_plan = o.plan
         and cp.stage = coalesce(o.commercial_stage, v_stage)
        where not o.is_admin_sandbox),

      -- Request volume is not metered anywhere in this schema. Rather than
      -- invent a number, report what IS recorded about API access and say so.
      'api', (select jsonb_build_object(
          'instrumented', false,
          'requests_30d', null,
          'keys_active', count(*) filter (where k.revoked_at is null and (k.expires_at is null or k.expires_at > now())),
          'keys_used_24h', count(*) filter (where k.last_used_at > now() - interval '24 hours'),
          'keys_total', count(*))
        from muster.api_keys k)),

    -- ---- 30-day activity, stacked by what triggered the scan --------------
    'activity', (select coalesce(jsonb_agg(jsonb_build_object(
          'day', d.day, 'scheduled', d.scheduled, 'manual', d.manual, 'other', d.other,
          'failed', d.failed, 'total', d.scheduled + d.manual + d.other) order by d.day), '[]'::jsonb)
      from (
        select g.day::date as day,
          count(*) filter (where s.trigger = 'scheduled') as scheduled,
          count(*) filter (where s.trigger = 'manual') as manual,
          count(*) filter (where s.id is not null and s.trigger not in ('scheduled', 'manual')) as other,
          count(*) filter (where s.status = 'failed') as failed
        from generate_series(current_date - interval '29 days', current_date, interval '1 day') g(day)
        left join muster.scans s on s.created_at >= g.day and s.created_at < g.day + interval '1 day'
        group by 1) d),

    -- ---- highest-severity open findings, newest first ---------------------
    'risk_watch', (select coalesce(jsonb_agg(x order by x->>'rank', x->>'last_seen_at' desc), '[]'::jsonb)
      from (
        select jsonb_build_object(
            'id', f.id, 'severity', f.severity, 'title', f.title, 'rule_id', f.rule_id,
            'organization', o.name, 'organization_id', o.id, 'website', w.name,
            'last_seen_at', f.last_seen_at, 'first_seen_at', f.first_seen_at,
            'rank', case f.severity when 'critical' then 1 when 'high' then 2 when 'medium' then 3 when 'low' then 4 else 5 end) as x
        from muster.findings f
        join muster.organizations o on o.id = f.organization_id
        left join muster.websites w on w.id = f.website_id
        where f.status in ('open', 'reopened') and f.severity in ('critical', 'high', 'medium')
        order by case f.severity when 'critical' then 1 when 'high' then 2 else 3 end, f.last_seen_at desc
        limit 8) s),

    -- ---- portfolio health -------------------------------------------------
    -- An org's band is its WORST site, not its average: a portfolio is as
    -- assured as the weakest thing in it. Bands use muster.posture_band's own
    -- thresholds so this agrees with every other score in the product.
    'org_health', (select jsonb_build_object(
        'total', count(*),
        'healthy', count(*) filter (where band = 'healthy'),
        'at_risk', count(*) filter (where band = 'at_risk'),
        'critical', count(*) filter (where band = 'critical'),
        'trial', count(*) filter (where band = 'trial'),
        'unscored', count(*) filter (where band = 'unscored'))
      from (
        select case
            when o.plan = 'trial' then 'trial'
            when s.worst is null then 'unscored'
            when muster.posture_band(s.worst) = 'green' then 'healthy'
            when muster.posture_band(s.worst) = 'amber' then 'at_risk'
            else 'critical' end as band
        from muster.organizations o
        left join lateral (
          select min(muster.posture_score(w.id)) as worst
          from muster.websites w where w.organization_id = o.id) s on true
        where not o.is_admin_sandbox) b),

    -- ---- most recent scans, one row per scan ------------------------------
    'recent_scans', (select coalesce(jsonb_agg(x order by x->>'at' desc), '[]'::jsonb)
      from (
        select jsonb_build_object(
            'id', s.id, 'organization', o.name, 'organization_id', o.id,
            'website', coalesce(w.name, s.target_url), 'website_id', w.id,
            'trigger', s.trigger, 'status', s.status,
            'score', case when w.id is null then null else muster.posture_score(w.id) end,
            'band', case when w.id is null then null else muster.posture_band(muster.posture_score(w.id)) end,
            'http_status', s.http_status, 'response_ms', s.response_ms,
            'at', coalesce(s.finished_at, s.started_at, s.queued_at, s.created_at)) as x
        from muster.scans s
        join muster.organizations o on o.id = s.organization_id
        left join muster.websites w on w.id = s.website_id
        order by coalesce(s.finished_at, s.started_at, s.queued_at, s.created_at) desc
        limit 8) r),

    -- ---- platform health --------------------------------------------------
    'system', jsonb_build_object(
      'incidents', (select jsonb_build_object(
          'open', count(*),
          'critical', count(*) filter (where i.severity = 'critical'),
          'warning', count(*) filter (where i.severity = 'warning'))
        from muster.incidents i where i.status not in ('closed', 'wont_fix')),
      'queue', jsonb_build_object(
        'queued', (select count(*) from muster.scans where status = 'queued'),
        'running', (select count(*) from muster.scans where status = 'running'),
        'oldest_queued_at', (select min(queued_at) from muster.scans where status = 'queued')),
      'alerts', jsonb_build_object(
        'pending', (select count(*) from muster.notification_outbox where status = 'pending'),
        'dead_letter', (select count(*) from muster.notification_outbox where status = 'failed' and attempts >= 5),
        'sent_24h', (select count(*) from muster.notification_outbox where status = 'sent' and sent_at > now() - interval '24 hours')),
      -- Schedules plus the last run each one actually completed. An active
      -- cron row proves only that a schedule exists; last_success_at is what
      -- proves it fired.
      'cron', (select coalesce(jsonb_agg(jsonb_build_object(
            'jobname', j.jobname, 'active', j.active, 'schedule', j.schedule,
            'last_success_at', r.last_success, 'last_status', r.last_status) order by j.jobname), '[]'::jsonb)
        from cron.job j
        left join lateral (
          select max(d.end_time) filter (where d.status = 'succeeded') as last_success,
                 (select d2.status from cron.job_run_details d2 where d2.jobid = j.jobid order by d2.start_time desc limit 1) as last_status
          from cron.job_run_details d where d.jobid = j.jobid) r on true
        where j.jobname like 'muster%')),

    -- ---- what a super admin should do next, computed not curated ----------
    -- Each row is a real count against a real table; a row with a zero count
    -- is omitted, so an empty list means there is genuinely nothing queued.
    'action_items', (select coalesce(jsonb_agg(jsonb_build_object(
          'rank', t.rank, 'key', t.key, 'severity', t.severity,
          'count', t.count, 'title', t.title, 'detail', t.detail) order by t.rank), '[]'::jsonb)
      from (values
        (1, 'incidents', 'critical',
          (select count(*) from muster.incidents where status not in ('closed', 'wont_fix') and severity = 'critical'),
          'Triage critical incidents', 'Opened by muster-watchdog and not yet closed'),
        (2, 'alert_dead_letter', 'critical',
          (select count(*) from muster.notification_outbox where status = 'failed' and attempts >= 5),
          'Alert emails in dead-letter', 'Failed five times and stopped retrying; check Resend'),
        (3, 'failed_scans', 'high',
          (select count(*) from muster.scans where status = 'failed' and finished_at > now() - interval '7 days'),
          'Review failed scans', 'Failed in the last 7 days and returned no findings'),
        (4, 'controls_not_met', 'high',
          (select count(*) from muster.controls c join muster.websites w on w.id = c.website_id
             join muster.organizations o on o.id = w.organization_id and not o.is_admin_sandbox
           where c.assessment = 'not_met'),
          'Controls assessed not met', 'Derived from scanner evidence; each needs a remediation owner'),
        (5, 'stuck_grants', 'high',
          (select count(*) from muster.pending_commercial_grants where applied_at is null and created_at < now() - interval '24 hours'),
          'Paid checkouts not yet claimed', 'Stripe took payment; no organization has claimed the grant'),
        (6, 'never_scanned', 'medium',
          (select count(*) from muster.websites w join muster.organizations o on o.id = w.organization_id and not o.is_admin_sandbox
           where not exists (select 1 from muster.scans s where s.website_id = w.id and s.status = 'complete')),
          'Websites never scanned', 'Registered but with no completed scan, so they score nothing'),
        (7, 'unverified', 'medium',
          (select count(*) from muster.websites w join muster.organizations o on o.id = w.organization_id and not o.is_admin_sandbox
           where w.verified_at is null),
          'Websites awaiting verification', 'Ownership unproven, so deep checks stay off'),
        (8, 'onboarding', 'medium',
          (select count(*) from muster.organizations where not is_admin_sandbox and onboarding_status <> 'complete'),
          'Organizations mid-onboarding', 'Provisioned but have not finished the guided wizard'),
        (9, 'jurisdictions', 'low',
          (select count(*) from muster.jurisdictions where reviewed_at < current_date - interval '180 days'),
          'Jurisdictions overdue for review', 'Law text last reviewed more than 180 days ago')
      ) as t(rank, key, severity, count, title, detail)
      where t.count > 0),

    -- ---- rosters the console's other sections render ----------------------
    'organizations', (select coalesce(jsonb_agg(jsonb_build_object(
          'id', o.id, 'name', o.name, 'plan', o.plan, 'stage', coalesce(o.commercial_stage, v_stage),
          'onboarding_status', o.onboarding_status, 'created_at', o.created_at,
          'is_admin_sandbox', o.is_admin_sandbox,
          'jurisdiction', nullif(concat_ws('-', o.country_code, o.region_code), ''),
          'members', (select count(*) from muster.organization_members m where m.organization_id = o.id),
          'websites', (select count(*) from muster.websites w where w.organization_id = o.id),
          'open_critical', (select count(*) from muster.findings f where f.organization_id = o.id and f.status in ('open','reopened') and f.severity = 'critical'),
          'open_high', (select count(*) from muster.findings f where f.organization_id = o.id and f.status in ('open','reopened') and f.severity = 'high'),
          'worst_score', (select min(muster.posture_score(w.id)) from muster.websites w where w.organization_id = o.id),
          'last_scan_at', (select max(s.finished_at) from muster.scans s where s.organization_id = o.id)) order by o.created_at desc), '[]'::jsonb)
      from muster.organizations o),

    'users', (select coalesce(jsonb_agg(jsonb_build_object(
          'id', u.id, 'name', u.name, 'email', u.email, 'role', u.role,
          'login_method', u.login_method, 'last_signed_in', u.last_signed_in, 'created_at', u.created_at,
          'memberships', (select count(*) from muster.organization_members m where m.user_id = u.id)) order by u.created_at desc), '[]'::jsonb)
      from muster.users u),

    'websites', (select coalesce(jsonb_agg(jsonb_build_object(
          'id', w.id, 'name', w.name, 'url', w.url, 'environment', w.environment,
          'organization', o.name, 'organization_id', o.id,
          'verified_at', w.verified_at,
          'score', muster.posture_score(w.id), 'band', muster.posture_band(muster.posture_score(w.id)),
          'open_findings', (select count(*) from muster.findings f where f.website_id = w.id and f.status in ('open','reopened')),
          'last_scan_at', (select max(s.finished_at) from muster.scans s where s.website_id = w.id and s.status = 'complete')) order by o.name, w.name), '[]'::jsonb)
      from muster.websites w join muster.organizations o on o.id = w.organization_id),

    'flags', (select coalesce(jsonb_agg(jsonb_build_object(
          'key', f.key, 'name', f.name, 'description', f.description, 'scope', f.scope,
          'default_enabled', f.default_enabled, 'plan_minimum', f.plan_minimum,
          'kill_switch', f.kill_switch, 'category', f.category, 'surface', f.surface,
          'enforcement', f.enforcement,
          'overrides', (select count(*) from muster.feature_flag_overrides fo where fo.flag_key = f.key)) order by f.category, f.key), '[]'::jsonb)
      from muster.feature_flags f),

    'pricing', public.muster_public_pricing());
end;
$function$;

comment on function public.muster_admin_console() is
  'Aggregate payload for the standalone Super Admin Console (admin.html). Super-admin gated. Figures with no instrumentation behind them return null plus instrumented:false rather than a placeholder.';

-- Same grant shape as every other muster_admin_* RPC: this one is called by a
-- signed-in super admin from the browser, and muster.is_super_admin() is the
-- gate. anon is revoked by name because Supabase's default privileges grant
-- EXECUTE on every new public function to anon AND authenticated, and
-- `revoke ... from public` does not undo a grant to a named role.
revoke all on function public.muster_admin_console() from public;
revoke all on function public.muster_admin_console() from anon;
grant execute on function public.muster_admin_console() to authenticated;
