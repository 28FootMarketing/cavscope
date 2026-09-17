-- muster_063: make "inactive" actually hold, at ingest.
--
-- Found while preparing the first real engine deploy since SEC-014, SEC-015 and
-- EMAIL-008 were added. Migration 20260916210100 holds those three rules
-- inactive, and both its header and CLAUDE.md describe that as what keeps an
-- unshipped rule from reaching a customer. It does not. It half does.
--
-- What active=false actually governed until now: rule_control_refs() projects
-- only active rules into the control register, so an inactive rule cannot render
-- as a met control. That is the failure 062 was written to prevent and it is
-- genuinely prevented.
--
-- What it did NOT govern: findings. muster.engine_ingest inserts every finding
-- the engine hands it, and findings.rule_id is a foreign key to
-- scan_rules(rule_id) -- which those three rows satisfy, because they exist and
-- are merely flagged inactive. The engine emits them unconditionally; there is
-- no active check anywhere in muster-scan.
--
-- So deploying the engine would have put SEC-014 (medium), SEC-015 (low) and
-- EMAIL-008 (low) into every tenant's risk register on the next scan, scoring
-- against their posture, while the console and the docs all said those rules
-- were not shipped. muster.autotriage() opens a risk for any finding at medium
-- or above, so SEC-014 would also have opened a risk per affected site. The
-- rules would have gone live by the back door, and the one place you would look
-- to confirm they had not -- scan_rules.active -- would still have said false.
--
-- The fix is one guard in the findings loop. An inactive rule's findings are
-- dropped on arrival, so "inactive" now means what everyone already believed:
-- the rule is not in play, for controls and for findings alike.
--
-- Two consequences worth stating rather than discovering:
--
--   * Deactivating a rule now retires its open findings. A dropped finding is
--     not observed by the scan, so the reconcile step below resolves whatever
--     that rule had open. That is the honest reading of "not in play" -- a rule
--     we are not running should not leave findings sitting open against a
--     customer forever -- and it is reversible: reactivate, rescan, and the
--     finding reopens against its existing fingerprint.
--   * Evidence is still recorded. Only findings are gated. The evidence rows an
--     inactive rule's check produced stay, so activating a rule later does not
--     lose the artefacts already collected, and so a scan's evidence count does
--     not silently change with a flag.
--
-- This does not activate anything. SEC-014, SEC-015 and EMAIL-008 stay inactive;
-- it just makes that mean something. Activation is still the single deliberate
-- statement in 20260916210100's header and docs/SCAN-RULES.md.

create or replace function muster.engine_ingest(p_scan_id bigint, p_scan jsonb, p_evidence jsonb, p_findings jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  v_scan      muster.scans%rowtype;
  v_ev        jsonb;
  v_f         jsonb;
  v_ev_map    jsonb := '{}'::jsonb;
  v_ev_id     bigint;
  v_fid       bigint;
  v_inserted  boolean;
  v_prev      text;
  v_seen      bigint[] := '{}';
  v_new       integer := 0;
  v_updated   integer := 0;
  v_reopened  integer := 0;
  v_resolved  integer := 0;
  v_skipped   integer := 0;
  v_counts    jsonb;
  v_score     integer;
begin
  select * into v_scan from muster.scans where id = p_scan_id for update;
  if not found then
    raise exception 'scan % not found', p_scan_id;
  end if;

  for v_ev in select * from jsonb_array_elements(coalesce(p_evidence, '[]'::jsonb)) loop
    insert into muster.scan_evidence
      (scan_id, organization_id, website_id, kind, url, http_status, content_type, response_ms, headers, excerpt, byte_length, sha256)
    values
      (p_scan_id, v_scan.organization_id, v_scan.website_id, v_ev->>'kind', left(v_ev->>'url', 2048),
       nullif(v_ev->>'http_status','')::integer, left(v_ev->>'content_type', 160), nullif(v_ev->>'response_ms','')::integer,
       case when jsonb_typeof(v_ev->'headers') = 'object' then v_ev->'headers' else null end,
       left(v_ev->>'excerpt', 8192), nullif(v_ev->>'byte_length','')::integer, nullif(v_ev->>'sha256',''))
    returning id into v_ev_id;
    v_ev_map := v_ev_map || jsonb_build_object(v_ev->>'key', v_ev_id);
  end loop;

  for v_f in select * from jsonb_array_elements(coalesce(p_findings, '[]'::jsonb)) loop
    -- An inactive rule is not in play. The engine has no idea which rules are
    -- active -- it emits everything it evaluates -- so this is the only place
    -- the distinction can be enforced. Unknown rule ids are let through to the
    -- foreign key, which is the right place to refuse them loudly.
    if exists (select 1 from muster.scan_rules r where r.rule_id = v_f->>'rule_id' and not r.active) then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    select f.status into v_prev
    from muster.findings f
    where f.website_id = v_scan.website_id
      and f.fingerprint = muster.finding_fingerprint(v_scan.website_id, v_f->>'rule_id', v_f->>'page_url', v_f->>'location');

    insert into muster.findings
      (organization_id, website_id, rule_id, fingerprint, severity, title, detail, page_url, location, confidence,
       first_seen_scan_id, last_seen_scan_id)
    values
      (v_scan.organization_id, v_scan.website_id, v_f->>'rule_id',
       muster.finding_fingerprint(v_scan.website_id, v_f->>'rule_id', v_f->>'page_url', v_f->>'location'),
       v_f->>'severity', left(v_f->>'title', 240), v_f->>'detail', left(v_f->>'page_url', 2048),
       left(v_f->>'location', 400), coalesce(v_f->>'confidence', 'high'), p_scan_id, p_scan_id)
    on conflict (website_id, fingerprint) do update set
      last_seen_scan_id = excluded.last_seen_scan_id,
      last_seen_at = now(),
      occurrences = muster.findings.occurrences + 1,
      detail = excluded.detail,
      severity = excluded.severity,
      confidence = excluded.confidence,
      status = case when muster.findings.status = 'resolved' then 'reopened' else muster.findings.status end,
      resolved_at = case when muster.findings.status = 'resolved' then null else muster.findings.resolved_at end,
      resolved_by_scan_id = case when muster.findings.status = 'resolved' then null else muster.findings.resolved_by_scan_id end
    returning id, (xmax = 0) into v_fid, v_inserted;

    if v_inserted then v_new := v_new + 1;
    elsif v_prev = 'resolved' then v_reopened := v_reopened + 1;
    else v_updated := v_updated + 1;
    end if;

    insert into muster.finding_evidence (finding_id, evidence_id, scan_id)
    select v_fid, (v_ev_map->>k)::bigint, p_scan_id
    from jsonb_array_elements_text(coalesce(v_f->'evidence_keys', '[]'::jsonb)) k
    where v_ev_map ? k
    on conflict do nothing;

    v_seen := v_seen || v_fid;
  end loop;

  -- Reconcile: open http_native findings not observed in this scan are resolved
  -- by it. A finding dropped above is not observed, so deactivating a rule
  -- retires what it had open. Reversible: reactivate, rescan, and it reopens
  -- against the same fingerprint.
  update muster.findings f
  set status = 'resolved', resolved_at = now(), resolved_by_scan_id = p_scan_id
  where f.website_id = v_scan.website_id
    and f.status in ('open','reopened')
    and not (f.id = any (v_seen))
    and exists (select 1 from muster.scan_rules r where r.rule_id = f.rule_id and r.check_type = 'http_native');
  get diagnostics v_resolved = row_count;

  select coalesce(jsonb_object_agg(s.severity, s.n), '{}'::jsonb) into v_counts
  from (select severity, count(*) n from muster.findings
        where website_id = v_scan.website_id and status in ('open','reopened') group by severity) s;
  v_score := muster.posture_score(v_scan.website_id);
  perform muster.do_ingest_controls(v_scan.website_id, v_scan.organization_id);

  update muster.scans set
    status = 'complete', finished_at = now(),
    final_url = left(p_scan->>'final_url', 1024),
    http_status = nullif(p_scan->>'http_status','')::integer,
    response_ms = nullif(p_scan->>'response_ms','')::integer,
    engine_version = left(p_scan->>'engine_version', 32),
    summary = jsonb_build_object(
      'open_by_severity', v_counts, 'new', v_new, 'updated', v_updated, 'reopened', v_reopened,
      'resolved', v_resolved, 'evidence', jsonb_array_length(coalesce(p_evidence, '[]'::jsonb)),
      -- Surfaced rather than swallowed: a non-zero count here is the engine
      -- reporting rules this database is not running, which is the signal that
      -- an activation is pending or an engine is ahead of its schema.
      'skipped_inactive', v_skipped,
      'posture_score', v_score, 'posture_band', muster.posture_band(v_score))
  where id = p_scan_id;

  update muster.website_scan_settings set last_run_at = now() where website_id = v_scan.website_id;

  insert into muster.activity_events (organization_id, entity_type, entity_id, action, detail, actor_id)
  values (v_scan.organization_id, 'scan', p_scan_id, 'Scan completed',
    format('%s new, %s reopened, %s resolved. Posture %s (%s).', v_new, v_reopened, v_resolved, v_score, muster.posture_band(v_score)),
    v_scan.requested_by_id);

  return jsonb_build_object('scan_id', p_scan_id, 'new', v_new, 'updated', v_updated, 'reopened', v_reopened,
    'resolved', v_resolved, 'skipped_inactive', v_skipped,
    'posture_score', v_score, 'posture_band', muster.posture_band(v_score));
end;
$function$;

revoke all on function muster.engine_ingest(bigint, jsonb, jsonb, jsonb) from public, anon, authenticated;
grant execute on function muster.engine_ingest(bigint, jsonb, jsonb, jsonb) to service_role;
