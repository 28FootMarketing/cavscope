-- muster.autotriage()'s risk_opened alert still said "MUSTER" in customer-
-- facing copy (subject: '[MUSTER] New %s risk...', body: 'MUSTER opened a
-- new...'), even though the URL inside it was already corrected to
-- app.muster.partners (muster_029) and every OTHER category this PR added
-- (sitrep_ready, workspace_created, website_added) already says "CavScope".
-- CLAUDE.md's brand note is explicit that muster/muster_* stays as the
-- internal schema/RPC/hostname identifier -- but this is customer-facing
-- email copy, the one thing that note says must read as CavScope. Caught by
-- actually sending a real rendered sample of this email and reading it.
CREATE OR REPLACE FUNCTION muster.autotriage()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'muster', 'public'
AS $function$
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
            format('[CavScope] New %s risk on %s: %s', upper(f.severity), f.website_name, f.title),
            format(E'CavScope opened a new %s-severity risk on %s (%s).\n\nFinding: %s\n%s\n\nRemediation: %s\n\nView full detail: https://app.muster.partners/app\n',
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
end $function$
;
