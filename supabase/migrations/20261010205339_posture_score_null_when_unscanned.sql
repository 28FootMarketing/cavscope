-- posture_score(site) returned 100 for a site with no completed scan: no findings summed to 0, so
-- 100 - 0. That is absence-of-findings read as a pass, and it rendered GREEN for a target the engine
-- never read. It now returns null until a scan on the site has completed, and posture_band(null) is
-- null, not 'red' (a null comparison fell through to the else branch).
--
-- engine_ingest scores the site BEFORE it sets the scan to 'complete', so with the guard it would have
-- scored every first scan null. It calls the unguarded formula instead (the scan it is finishing is,
-- by definition, about to be a completed one). Nothing else does.
create or replace function cavscope.posture_score_from_findings(p_website_id bigint)
 returns integer language sql stable security definer set search_path to ''
as $f$
  select greatest(0, 100 - coalesce(sum(cavscope.severity_weight(f.severity)), 0))::integer
  from cavscope.findings f
  where f.website_id = p_website_id and f.status in ('open','reopened');
$f$;
revoke all on function cavscope.posture_score_from_findings(bigint) from public, anon, authenticated;

create or replace function cavscope.posture_score(p_website_id bigint)
 returns integer language sql stable security definer set search_path to ''
as $f$
  select case when exists (select 1 from cavscope.scans s where s.website_id = p_website_id and s.status = 'complete')
              then cavscope.posture_score_from_findings(p_website_id) end;
$f$;

create or replace function cavscope.posture_band(p_score integer)
 returns text language sql immutable set search_path to ''
as $f$
  select case when p_score is null then null when p_score >= 85 then 'green' when p_score >= 60 then 'amber' else 'red' end;
$f$;

do $$
declare v_def text; v_new text;
begin
  v_def := pg_get_functiondef('cavscope.engine_ingest(bigint,jsonb,jsonb,jsonb)'::regprocedure);
  v_new := replace(v_def, 'v_score := cavscope.posture_score(v_scan.website_id);', 'v_score := cavscope.posture_score_from_findings(v_scan.website_id);');
  if v_new = v_def or (length(v_def) - length(replace(v_def, 'cavscope.posture_score(v_scan.website_id)', ''))) <> length('cavscope.posture_score(v_scan.website_id)') then
    raise exception 'engine_ingest anchor did not match exactly once';
  end if;
  execute v_new;
end $$;
