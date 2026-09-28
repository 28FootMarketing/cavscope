-- Fixes a second real defect the sandbox rescans surfaced: engine_ingest's
-- jurisdiction write only fired when p_scan->>'detected_country_code' was NOT
-- null, on the reasoning that a scan finding nothing should not erase a state
-- a PRIOR scan actually detected. That reasoning breaks the moment the prior
-- detection was itself wrong: after migration 20260928170144's 1.14.0 fix for
-- the "Anthony Washington Sr." false positive, anthonywashingtonsr.com (After
-- Today LLC's own site, actually in Hanover, PA) was rescanned, its /about
-- page was refetched, and the engine correctly computed no state -- but
-- ingest's null-guard silently refused to write that correction over the
-- stale WA value from before the fix, so the wrong jurisdiction survived a
-- scan that had already disproven it. Confirmed live: website 19's evidence
-- for scan 184 shows /about was refetched; websites.detected_region_code
-- still read 'WA' afterward.
--
-- The guard's stated worry -- a bounded 3-fetch follow-up reaching a
-- different page than last time and "losing" a real detection -- is not
-- actually protected by refusing nulls: the same site, same anchors, same
-- fetch order produces the same candidate list every scan, so a genuine
-- disappearance is itself a signal (the page changed) worth reflecting, not
-- worth hiding behind stale data. Every engine since http-native-1.11.0 always
-- sends this key (explicitly "US"/code or null); only a pre-1.11.0 payload
-- could omit it entirely, and no such engine has been deployed since 1.14.0
-- shipped. So the safe, correct behaviour going forward is to write the
-- latest scan's answer unconditionally, including null.

create or replace function cavscope.engine_ingest(p_scan_id bigint, p_scan jsonb, p_evidence jsonb, p_findings jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  v_scan      cavscope.scans%rowtype;
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
  select * into v_scan from cavscope.scans where id = p_scan_id for update;
  if not found then
    raise exception 'scan % not found', p_scan_id;
  end if;

  for v_ev in select * from jsonb_array_elements(coalesce(p_evidence, '[]'::jsonb)) loop
    insert into cavscope.scan_evidence
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
    if exists (select 1 from cavscope.scan_rules r where r.rule_id = v_f->>'rule_id' and not r.active) then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    select f.status into v_prev
    from cavscope.findings f
    where f.website_id = v_scan.website_id
      and f.fingerprint = cavscope.finding_fingerprint(v_scan.website_id, v_f->>'rule_id', v_f->>'page_url', v_f->>'location');

    insert into cavscope.findings
      (organization_id, website_id, rule_id, fingerprint, severity, title, detail, page_url, location, confidence,
       first_seen_scan_id, last_seen_scan_id)
    values
      (v_scan.organization_id, v_scan.website_id, v_f->>'rule_id',
       cavscope.finding_fingerprint(v_scan.website_id, v_f->>'rule_id', v_f->>'page_url', v_f->>'location'),
       v_f->>'severity', left(v_f->>'title', 240), v_f->>'detail', left(v_f->>'page_url', 2048),
       left(v_f->>'location', 400), coalesce(v_f->>'confidence', 'high'), p_scan_id, p_scan_id)
    on conflict (website_id, fingerprint) do update set
      last_seen_scan_id = excluded.last_seen_scan_id,
      last_seen_at = now(),
      occurrences = cavscope.findings.occurrences + 1,
      detail = excluded.detail,
      severity = excluded.severity,
      confidence = excluded.confidence,
      status = case when cavscope.findings.status = 'resolved' then 'reopened' else cavscope.findings.status end,
      resolved_at = case when cavscope.findings.status = 'resolved' then null else cavscope.findings.resolved_at end,
      resolved_by_scan_id = case when cavscope.findings.status = 'resolved' then null else cavscope.findings.resolved_by_scan_id end
    returning id, (xmax = 0) into v_fid, v_inserted;

    if v_inserted then v_new := v_new + 1;
    elsif v_prev = 'resolved' then v_reopened := v_reopened + 1;
    else v_updated := v_updated + 1;
    end if;

    insert into cavscope.finding_evidence (finding_id, evidence_id, scan_id)
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
  update cavscope.findings f
  set status = 'resolved', resolved_at = now(), resolved_by_scan_id = p_scan_id
  where f.website_id = v_scan.website_id
    and f.status in ('open','reopened')
    and not (f.id = any (v_seen))
    and exists (select 1 from cavscope.scan_rules r where r.rule_id = f.rule_id and r.check_type = 'http_native');
  get diagnostics v_resolved = row_count;

  select coalesce(jsonb_object_agg(s.severity, s.n), '{}'::jsonb) into v_counts
  from (select severity, count(*) n from cavscope.findings
        where website_id = v_scan.website_id and status in ('open','reopened') group by severity) s;
  v_score := cavscope.posture_score(v_scan.website_id);
  perform cavscope.do_ingest_controls(v_scan.website_id, v_scan.organization_id);

  -- Jurisdiction signal: written unconditionally from this scan's answer,
  -- including null. A scan that finds nothing is not "no information" --
  -- it is this engine's current, best answer for this site, from the same
  -- pages in the same order every time, and a stale wrong value must not
  -- outlive the scan that already disproved it. See this migration's header
  -- for the live case that forced this (anthonywashingtonsr.com, WA).
  update cavscope.websites
     set detected_country_code = p_scan->>'detected_country_code',
         detected_region_code = p_scan->>'detected_region_code'
   where id = v_scan.website_id;

  update cavscope.scans set
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
      'posture_score', v_score, 'posture_band', cavscope.posture_band(v_score))
  where id = p_scan_id;

  update cavscope.website_scan_settings set last_run_at = now() where website_id = v_scan.website_id;

  insert into cavscope.activity_events (organization_id, entity_type, entity_id, action, detail, actor_id)
  values (v_scan.organization_id, 'scan', p_scan_id, 'Scan completed',
    format('%s new, %s reopened, %s resolved. Posture %s (%s).', v_new, v_reopened, v_resolved, v_score, cavscope.posture_band(v_score)),
    v_scan.requested_by_id);

  return jsonb_build_object('scan_id', p_scan_id, 'new', v_new, 'updated', v_updated, 'reopened', v_reopened,
    'resolved', v_resolved, 'skipped_inactive', v_skipped,
    'posture_score', v_score, 'posture_band', cavscope.posture_band(v_score));
end;
$function$;

-- Repairs the one row already known wrong from this exact bug, rather than
-- waiting for a rescan to happen to fix it as a side effect.
update cavscope.websites
   set detected_country_code = null, detected_region_code = null
 where id = 19 and detected_region_code = 'WA';

do $$
declare v_stale integer;
begin
  select count(*) into v_stale from cavscope.websites where id = 19 and detected_region_code = 'WA';
  if v_stale <> 0 then
    raise exception 'website 19 still shows a stale WA detection after repair';
  end if;
end $$;
