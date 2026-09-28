-- Consolidates risk_opened alert email: a scan (or several, picked up by the
-- same autotriage() run) that opens more than one critical/high risk used to
-- queue one notification_outbox row -- and one email -- per risk. Anthony
-- asked for these to be one email, not several.
--
-- Grouped by organization_id, not by scan_id or website_id: a single
-- autotriage tick can pick up newly-triaged findings from several completed
-- scans across an org's sites in one pass (it has no LIMIT and no per-scan
-- boundary of its own -- see muster-autotriage-15min's schedule), and those
-- belong in one digest too, not one email per site.
--
-- anchor_risk_id (the highest risk id in the batch) is what
-- (entity_type, entity_id, category) uniqueness keys off, still with
-- entity_type = 'risk' -- notification_outbox.entity_type's CHECK constraint
-- has no 'batch' or 'scan' value, and doesn't need one: a risk id is created
-- exactly once, ever (the finding loop above only ever visits a finding whose
-- risk_id is still null), so it can never collide with a later run's batch
-- the way an organization- or website-keyed id would.
CREATE OR REPLACE FUNCTION cavscope.autotriage()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'cavscope', 'public'
AS $function$
declare f record; rid bigint; opened int := 0; closed int := 0; drifted int := 0; sc record; queued int := 0;
  v_org record; v_recipients text[]; v_alert_risks jsonb := '[]'::jsonb; v_batch record;
begin
  for sc in select s.id from cavscope.scans s left join cavscope.scan_postprocess p on p.scan_id = s.id
            where s.status='complete' and p.drift_done_at is null order by s.id limit 50
  loop drifted := drifted + cavscope.drift_detect(sc.id); end loop;

  for f in
    select fi.*, w.owner_id, w.name as website_name, w.url as website_url,
           r.category as rule_category, r.remediation, r.plain_english
    from cavscope.findings fi
    join cavscope.websites w on w.id = fi.website_id
    left join cavscope.scan_rules r on r.rule_id = fi.rule_id
    where fi.status in ('open','reopened') and fi.risk_id is null and fi.severity in ('critical','high','medium')
  loop
    insert into cavscope.risks (website_id, title, description, category, source, severity, status, inherent_score, residual_score, treatment, treatment_plan, owner_id, identified_at, target_date)
    values (f.website_id, f.title, coalesce(f.plain_english, f.detail), coalesce(f.rule_category,'governance'),
      case coalesce(f.rule_category,'') when 'privacy' then 'privacy_assessment' when 'accessibility' then 'accessibility_audit' when 'third_party' then 'vendor_assessment' else 'security_scan' end,
      f.severity, 'open',
      case f.severity when 'critical' then 20 when 'high' then 15 else 9 end,
      case f.severity when 'critical' then 20 when 'high' then 15 else 9 end,
      'mitigate', f.remediation, f.owner_id, coalesce(f.first_seen_at, now()),
      now() + case f.severity when 'critical' then interval '7 days' when 'high' then interval '30 days' else interval '90 days' end)
    returning id into rid;
    insert into cavscope.remediation_actions (risk_id, title, description, status, progress, owner_id, due_date, escalation_status)
    values (rid, 'Fix: ' || f.title, coalesce(f.remediation, f.detail), 'not_started', 0, f.owner_id,
      now() + case f.severity when 'critical' then interval '7 days' when 'high' then interval '30 days' else interval '90 days' end, 'none');
    update cavscope.findings set risk_id = rid where id = f.id;
    insert into cavscope.activity_events (organization_id, entity_type, entity_id, action, detail)
    values (f.organization_id, 'risk', rid, 'auto_opened', format('Opened from finding %s (%s)', f.rule_id, f.severity));
    opened := opened + 1;

    if f.severity in ('critical','high') then
      v_alert_risks := v_alert_risks || jsonb_build_object(
        'risk_id', rid,
        'organization_id', f.organization_id,
        'website_name', f.website_name,
        'website_url', f.website_url,
        'severity', f.severity,
        'title', f.title,
        'detail', coalesce(f.plain_english, f.detail),
        'remediation', coalesce(f.remediation, 'See dashboard for recommended remediation.')
      );
    end if;
  end loop;

  for v_batch in
    select
      (elem->>'organization_id')::bigint as organization_id,
      max((elem->>'risk_id')::bigint) as anchor_risk_id,
      count(*) as risk_count,
      count(*) filter (where elem->>'severity' = 'critical') as critical_count,
      count(*) filter (where elem->>'severity' = 'high') as high_count,
      string_agg(distinct elem->>'website_name', ', ') as website_names,
      string_agg(
        format(E'[%s] %s\n%s\n\nRemediation: %s',
          upper(elem->>'severity'), elem->>'title', elem->>'detail', elem->>'remediation'),
        E'\n\n---\n\n'
        order by (elem->>'severity' <> 'critical'), elem->>'title'
      ) as risk_lines
    from jsonb_array_elements(v_alert_risks) elem
    group by 1
  loop
    select o.* into v_org from cavscope.organizations o where o.id = v_batch.organization_id;
    if v_org.critical_alerts_enabled then
      select coalesce(array_agg(distinct u.email), '{}')
        into v_recipients
        from cavscope.organization_members om
        join cavscope.users u on u.id = om.user_id
        where om.organization_id = v_batch.organization_id
          and om.role in ('executive','risk_owner');
      if array_length(v_recipients, 1) > 0 then
        insert into cavscope.notification_outbox
          (organization_id, category, entity_type, entity_id, severity, subject, body_text, recipient_emails)
        values (
          v_batch.organization_id, 'risk_opened', 'risk', v_batch.anchor_risk_id,
          case when v_batch.critical_count > 0 then 'critical' else 'high' end,
          format('[CavScope] %s new %s on %s (%s)',
            v_batch.risk_count, case when v_batch.risk_count = 1 then 'risk' else 'risks' end,
            v_batch.website_names,
            concat_ws(', ',
              case when v_batch.critical_count > 0 then v_batch.critical_count || ' critical' end,
              case when v_batch.high_count > 0 then v_batch.high_count || ' high' end)),
          format(E'CavScope opened %s new %s on %s from the latest scan activity.\n\n%s\n\nView full detail: https://app.muster.partners/app#risks\n',
            v_batch.risk_count, case when v_batch.risk_count = 1 then 'risk' else 'risks' end,
            v_batch.website_names, v_batch.risk_lines),
          v_recipients
        )
        on conflict (entity_type, entity_id, category) do nothing;
        queued := queued + 1;
      else
        insert into cavscope.activity_events (organization_id, entity_type, entity_id, action, detail)
        values (v_batch.organization_id, 'risk', v_batch.anchor_risk_id, 'alert_skipped_no_recipient',
          'No org member with role executive/risk_owner -- risk alert not queued');
      end if;
    end if;
  end loop;

  for f in
    select fi.id, fi.risk_id, fi.organization_id from cavscope.findings fi join cavscope.risks r on r.id = fi.risk_id
    where fi.status = 'resolved' and r.status in ('open','in_progress')
  loop
    update cavscope.risks set status='mitigated', residual_score = least(residual_score, 4), updated_at = now() where id = f.risk_id;
    update cavscope.remediation_actions set status='verified', progress=100, verified_at=now(), status_update='Verified by rescan', updated_at=now()
      where risk_id = f.risk_id and status <> 'verified';
    insert into cavscope.activity_events (organization_id, entity_type, entity_id, action, detail)
    values (f.organization_id, 'risk', f.risk_id, 'auto_mitigated', 'Finding no longer detected by scan engine');
    closed := closed + 1;
  end loop;

  update cavscope.risks r set status='open', updated_at=now()
    from cavscope.findings fi where fi.risk_id = r.id and fi.status='reopened' and r.status in ('mitigated','closed');

  return jsonb_build_object('drift_events', drifted, 'risks_opened', opened, 'risks_mitigated', closed, 'alerts_queued', queued);
end $function$
;
