-- The SITREP payload render.py consumes. One row, one JSON object.
--   psql "$MUSTER_DB_URL" -At -f export.sql -v sitrep_id=16 > sitrep-16.json
--
-- Everything here is read from what the engine already stored. The query adds
-- two things the SITREP row does not carry on its own: the findings this site
-- has resolved (the remediation record a client actually wants to see) and the
-- posture of every completed scan, so the trend is in the document rather than
-- asserted in a covering email.
select jsonb_pretty(jsonb_build_object(
  'org', o.name,
  'website', jsonb_build_object('name', w.name, 'url', w.url),
  'sitrep', jsonb_build_object(
     'id', s.id, 'version', s.version, 'status', s.status, 'generator', s.generator,
     'posture_score', s.posture_score, 'posture_band', s.posture_band,
     'headline', s.headline, 'generated_at', s.generated_at,
     'content_sha256', s.content_sha256),
  'scan', s.sections->'scan',
  'claims', s.sections->'board_report'->'claims',
  'top_findings', s.sections->'top_findings',
  'plain_english', s.sections->'plain_english'->'items',
  'evidence_index', s.sections->'evidence_index',
  'resolved', coalesce((
     select jsonb_agg(jsonb_build_object(
              'rule_id', f.rule_id, 'severity', f.severity, 'title', f.title,
              'location', f.location, 'first_seen_scan_id', f.first_seen_scan_id,
              'last_seen_scan_id', f.last_seen_scan_id, 'resolved_at', f.resolved_at,
              'framework_refs', coalesce(r.framework_refs, '{}'::jsonb))
            order by case f.severity
                       when 'critical' then 1 when 'high' then 2 when 'medium' then 3
                       when 'low' then 4 else 5 end, f.rule_id)
     from muster.findings f
     left join muster.scan_rules r on r.rule_id = f.rule_id
     where f.website_id = s.website_id and f.status = 'resolved'), '[]'::jsonb),
  'history', coalesce((
     select jsonb_agg(jsonb_build_object(
              'scan_id', sc.id, 'finished_at', sc.finished_at,
              'engine_version', sc.engine_version, 'response_ms', sc.response_ms,
              'posture_score', sp.posture_score, 'posture_band', sp.posture_band)
            order by sc.id)
     from muster.scans sc
     -- The latest SITREP for each scan: regenerating one adds a version rather
     -- than replacing it, so max(id) is the current view of that scan.
     left join muster.sitreps sp
            on sp.scan_id = sc.id
           and sp.id = (select max(id) from muster.sitreps where scan_id = sc.id)
     where sc.website_id = s.website_id and sc.status = 'complete'), '[]'::jsonb)
))
from muster.sitreps s
join muster.websites w on w.id = s.website_id
join muster.organizations o on o.id = s.organization_id
where s.id = :sitrep_id;
