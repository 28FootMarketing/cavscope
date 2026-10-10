-- Website Assurance wiring pass (admin.html), and the same flaw wherever the console scores a site.
--
-- cavscope.posture_score(website) is 100 minus the weight of open findings, so a site that has
-- never been scanned scores 100 and reads green: absence of findings as a pass. The console
-- showed that score for a registered site nobody had scanned yet, and banded an organization by
-- it (an organization whose only site was unscanned read as healthy rather than unscored).
-- The payload now scores a site only when a scan has completed on it:
--   websites[].scanned / score / band, plus websites[].sandbox (18 of the 20 sites on file are
--   sandbox prospects; the roster could not tell them from a customer's);
--   organizations[].worst_score and org_health use the worst SCANNED site;
--   recent_scans[].score / band are null for a scan on a site with no completed scan.
-- Each in-place edit must apply exactly once or the migration aborts.

create or replace function pg_temp.sub(src text, old text, new text) returns text
language plpgsql as $f$
declare n int;
begin
  n := (length(src) - length(replace(src, old, ''))) / length(old);
  if n <> 1 then raise exception 'expected exactly 1 match, found % for: %', n, left(old, 80); end if;
  return replace(src, old, new);
end $f$;

do $mig$
declare
  d text;
  scanned text := 'exists (select 1 from cavscope.scans sc where sc.website_id = w.id and sc.status = ''complete'')';
begin
  select pg_get_functiondef(p.oid) into d
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'cavscope_admin_console';

  -- Websites roster: score and band only for a site a scan has completed on, and say whether it is sandbox.
  d := pg_temp.sub(d, '''score'', cavscope.posture_score(w.id), ''band'', cavscope.posture_band(cavscope.posture_score(w.id)),',
    '''sandbox'', o.is_admin_sandbox,
          ''scanned'', ' || scanned || ',
          ''score'', case when ' || scanned || ' then cavscope.posture_score(w.id) end,
          ''band'', case when ' || scanned || ' then cavscope.posture_band(cavscope.posture_score(w.id)) end,');

  -- Organization roster: the worst score is the worst SCANNED site.
  d := pg_temp.sub(d, '''worst_score'', (select min(cavscope.posture_score(w.id)) from cavscope.websites w where w.organization_id = o.id),',
    '''worst_score'', (select min(cavscope.posture_score(w.id)) from cavscope.websites w where w.organization_id = o.id and ' || scanned || '),');

  -- Organization health bands: same rule.
  d := pg_temp.sub(d, 'select min(cavscope.posture_score(w.id)) as worst',
    'select min(cavscope.posture_score(w.id)) filter (where ' || scanned || ') as worst');

  -- Recent scans: a queued or failed scan on a never-completed site has no score to show.
  d := pg_temp.sub(d, '''score'', case when w.id is null then null else cavscope.posture_score(w.id) end,',
    '''score'', case when w.id is null or not ' || scanned || ' then null else cavscope.posture_score(w.id) end,');
  d := pg_temp.sub(d, '''band'', case when w.id is null then null else cavscope.posture_band(cavscope.posture_score(w.id)) end,',
    '''band'', case when w.id is null or not ' || scanned || ' then null else cavscope.posture_band(cavscope.posture_score(w.id)) end,');
  execute d;
end $mig$;
