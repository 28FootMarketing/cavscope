-- MUSTER 078: two corrections to 20260918-muster_077, both mine, both found by
-- reading the output rather than the code.
--
-- 1. The citation trim took an arbitrary five. `limit 5` was applied to an unordered
--    subquery, so the YMCA report cited [F305][F307][F308][F309][F310][+9 more] --
--    skipping F306 for no reason a reader could work out. The trim is a readability
--    device; it has to be the first five by id or it looks like the report lost one.
--    Ordering is now applied before the limit, and numerically rather than
--    lexicographically, so F9 sorts before F10.
--
-- 2. "This scan added 1 findings." The counts were interpolated as text with a hard
--    -s. On a document whose entire pitch is that it was written for the reader, a
--    grammar error in the second line of the Board Report costs more than it should.

create or replace function muster.generate_sitrep(p_scan_id bigint)
 returns bigint
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  -- A cap that announces itself. 50 is far above anything the homepage-only engine
  -- can currently produce (48 rules), so in practice it never binds -- but when a
  -- future engine makes it bind, the report says so rather than trimming in silence.
  c_max_findings constant integer := 50;
  v         record;
  v_score   integer;
  v_band    text;
  v_open    integer; v_crit integer; v_high integer; v_med integer; v_low integer; v_info integer;
  v_primary bigint;
  v_top     jsonb := '[]'::jsonb;
  v_claims  jsonb := '[]'::jsonb;
  v_plain   jsonb := '[]'::jsonb;
  v_scope   jsonb := '[]'::jsonb;
  v_cites   jsonb := '[]'::jsonb;
  v_evidx   jsonb;
  v_open_ids bigint[];
  v_md      text;
  v_headline text;
  v_version integer;
  v_id      bigint;
  f         record;
  i         integer := 0;
  c         integer := 0;
  v_cite    text;
  v_prev    integer;
  v_shown   integer := 0;
  v_worst   record;
  v_unread  boolean;
  v_skipped integer;
  v_line    text;
  v_n_new   integer;
  v_n_reop  integer;
  v_n_res   integer;
begin
  select s.*, w.name as website_name, w.url as website_url, o.name as org_name
  into v
  from muster.scans s
  join muster.websites w on w.id = s.website_id
  join muster.organizations o on o.id = w.organization_id
  where s.id = p_scan_id;
  if not found or v.status <> 'complete' then
    raise exception 'scan % is not complete', p_scan_id;
  end if;

  v_score := muster.posture_score(v.website_id);
  v_band := muster.posture_band(v_score);

  select count(*), count(*) filter (where severity='critical'), count(*) filter (where severity='high'),
         count(*) filter (where severity='medium'), count(*) filter (where severity='low'), count(*) filter (where severity='info'),
         coalesce(array_agg(id), '{}')
  into v_open, v_crit, v_high, v_med, v_low, v_info, v_open_ids
  from muster.findings where website_id = v.website_id and status in ('open','reopened');

  select id into v_primary from muster.scan_evidence
  where scan_id = p_scan_id and kind = 'http_response' order by id limit 1;

  select posture_score into v_prev
  from muster.sitreps
  where website_id = v.website_id and scan_id <> p_scan_id
  order by id desc limit 1;

  select fi.id, fi.severity, fi.title into v_worst
  from muster.findings fi
  where fi.website_id = v.website_id and fi.status in ('open','reopened')
  order by muster.severity_rank(fi.severity), fi.id
  limit 1;

  v_unread := v.http_status is null
    or exists (select 1 from muster.findings fi
               where fi.website_id = v.website_id and fi.status in ('open','reopened')
                 and fi.rule_id in ('AVAIL-001','AVAIL-003','AVAIL-004'));
  v_skipped := coalesce((v.summary->>'skipped_inactive')::integer, 0);
  v_n_new  := coalesce((v.summary->>'new')::integer, 0);
  v_n_reop := coalesce((v.summary->>'reopened')::integer, 0);
  v_n_res  := coalesce((v.summary->>'resolved')::integer, 0);

  c := c + 1;
  v_claims := v_claims || jsonb_build_object('id', 'C'||c,
    'text', format('Overall website assurance posture is %s of 100 (%s).', v_score, v_band),
    'finding_ids', to_jsonb(v_open_ids), 'evidence_ids', to_jsonb(array_remove(array[v_primary], null)));

  c := c + 1;
  if v_prev is null then
    v_line := 'This is the first report for this site, so there is no previous score to compare against.';
  elsif v_score > v_prev then
    v_line := format('Posture improved from %s to %s since the previous report (+%s).', v_prev, v_score, v_score - v_prev);
  elsif v_score < v_prev then
    v_line := format('Posture fell from %s to %s since the previous report (%s).', v_prev, v_score, v_score - v_prev);
  else
    v_line := format('Posture is unchanged at %s since the previous report.', v_score);
  end if;
  v_line := v_line || format(' This scan added %s new finding%s, reopened %s and resolved %s.',
    v_n_new, case when v_n_new = 1 then '' else 's' end, v_n_reop, v_n_res);
  v_claims := v_claims || jsonb_build_object('id', 'C'||c, 'text', v_line,
    'finding_ids', '[]'::jsonb, 'evidence_ids', '[]'::jsonb);

  c := c + 1;
  if v_worst.id is null then
    v_line := 'No findings are open against this site.';
    v_claims := v_claims || jsonb_build_object('id', 'C'||c, 'text', v_line,
      'finding_ids', '[]'::jsonb, 'evidence_ids', '[]'::jsonb);
  else
    v_line := format('The most severe open item is %s (%s).', v_worst.title, v_worst.severity);
    v_claims := v_claims || jsonb_build_object('id', 'C'||c, 'text', v_line,
      'finding_ids', to_jsonb(array[v_worst.id]), 'evidence_ids', '[]'::jsonb);
  end if;

  c := c + 1;
  v_claims := v_claims || jsonb_build_object('id', 'C'||c,
    'text', format('%s open finding%s: %s critical, %s high, %s medium, %s low, %s informational.',
      v_open, case when v_open = 1 then '' else 's' end, v_crit, v_high, v_med, v_low, v_info),
    'finding_ids', to_jsonb(v_open_ids), 'evidence_ids', '[]'::jsonb);

  c := c + 1;
  if v.http_status is not null then
    v_line := format('The homepage returned HTTP %s in %s ms from %s.',
      v.http_status, coalesce(v.response_ms::text,'an unrecorded number of'), coalesce(v.final_url, v.target_url));
  else
    v_line := format('No readable HTTP response was returned by %s, so no page content, headers or cookies were read. The finding below explains what happened; every HTTP-derived check produced nothing for this scan.',
      coalesce(v.final_url, v.target_url));
  end if;
  v_claims := v_claims || jsonb_build_object('id', 'C'||c, 'text', v_line,
    'finding_ids', '[]'::jsonb, 'evidence_ids', to_jsonb(array_remove(array[v_primary], null)));

  for f in
    select fi.id, fi.rule_id, fi.severity, fi.title, fi.detail, fi.page_url, fi.location, fi.confidence, fi.status,
           r.category, r.remediation, r.plain_english, r.framework_refs,
           coalesce((select array_agg(fe.evidence_id order by fe.evidence_id) from muster.finding_evidence fe where fe.finding_id = fi.id), '{}') as ev_ids
    from muster.findings fi join muster.scan_rules r on r.rule_id = fi.rule_id
    where fi.website_id = v.website_id and fi.status in ('open','reopened')
    order by muster.severity_rank(fi.severity), fi.last_seen_at desc, fi.id
    limit c_max_findings
  loop
    i := i + 1;
    v_top := v_top || jsonb_build_object('rank', i, 'finding_id', f.id, 'rule_id', f.rule_id, 'category', f.category,
      'severity', f.severity, 'status', f.status, 'title', f.title, 'detail', f.detail, 'page_url', f.page_url,
      'location', f.location, 'confidence', f.confidence, 'remediation', f.remediation,
      'framework_refs', f.framework_refs, 'evidence_ids', to_jsonb(f.ev_ids));
    v_plain := v_plain || jsonb_build_object('id', 'P'||i, 'finding_id', f.id,
      'text', f.plain_english || ' Fix: ' || f.remediation,
      'evidence_ids', to_jsonb(f.ev_ids));
  end loop;
  v_shown := i;

  if v_open > v_shown then
    c := c + 1;
    v_claims := v_claims || jsonb_build_object('id', 'C'||c,
      'text', format('This report details the %s most severe of %s open findings. The remaining %s are in the MUSTER workspace under this site''s risk register.',
        v_shown, v_open, v_open - v_shown),
      'finding_ids', '[]'::jsonb, 'evidence_ids', '[]'::jsonb);
  end if;

  v_scope := v_scope || to_jsonb('MUSTER reads this site over HTTP and DNS only. It does not execute JavaScript, so anything a page builds in the browser after load is not assessed.'::text);
  v_scope := v_scope || to_jsonb('It reads the homepage and a small set of well-known paths. It does not crawl the whole site, so a finding absent here may still exist on a page that was not fetched.'::text);
  v_scope := v_scope || to_jsonb('It never signs in. Nothing behind a login, paywall or member area is assessed.'::text);
  v_scope := v_scope || to_jsonb('Framework and statute references are citations, not test results. They say which control family a finding belongs to. They never assert that MUSTER tested that control, and this report is not a SOC 2 opinion, an accessibility audit of record, or legal advice.'::text);
  v_scope := v_scope || to_jsonb('A clean result is evidence that these specific checks passed on this date. It is not a statement that the site is secure.'::text);
  if v_unread then
    v_scope := v_scope || to_jsonb('On this scan the engine did not read the page at all, so every HTTP-derived check is unassessed rather than passed. The score reflects an unread target. DNS-derived checks (SPF, DMARC, CAA, MTA-STS) do not depend on the web server and did run.'::text);
  end if;
  if v_skipped > 0 then
    v_scope := v_scope || to_jsonb(format('%s finding(s) produced by rules not yet activated were withheld from this report.', v_skipped)::text);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('evidence_id', e.id, 'kind', e.kind, 'url', e.url,
           'http_status', e.http_status, 'sha256', e.sha256, 'captured_at', e.captured_at) order by e.id), '[]'::jsonb)
  into v_evidx
  from muster.scan_evidence e where e.scan_id = p_scan_id;

  select coalesce(jsonb_agg(jsonb_build_object('claim_id', x->>'id', 'finding_ids', x->'finding_ids', 'evidence_ids', x->'evidence_ids')), '[]'::jsonb)
  into v_cites from jsonb_array_elements(v_claims) x;
  select v_cites || coalesce(jsonb_agg(jsonb_build_object('claim_id', 'T'||(x->>'rank'),
           'finding_ids', jsonb_build_array(x->'finding_id'), 'evidence_ids', x->'evidence_ids')), '[]'::jsonb)
  into v_cites from jsonb_array_elements(v_top) x;

  v_headline := format('%s: posture %s/100 (%s), %s open findings, %s critical', v.website_name, v_score, v_band, v_open, v_crit);

  v_md := format(E'# SITREP: %s\n\n| | |\n|---|---|\n| Organization | %s |\n| Target | %s |\n| Scan | #%s, completed %s |\n| Engine | %s |\n| Posture | %s / 100 (%s) |\n\nPrepared by MUSTER. Every statement below cites a finding [F] or captured evidence [E] row.\n\n## Board Report\n\n',
    v.website_name, v.org_name, v.target_url, p_scan_id,
    to_char(v.finished_at at time zone 'UTC', 'YYYY-MM-DD HH24:MI UTC'),
    coalesce(v.engine_version,'n/a'), v_score, v_band);

  for f in select x from jsonb_array_elements(v_claims) x loop
    -- The first five by id, ordered before the limit and numerically, so the trim
    -- reads as a trim rather than as a report that mislaid a finding.
    select string_agg('[F'||y||']', '' order by y::bigint) into v_cite
      from (select y from jsonb_array_elements_text(f.x->'finding_ids') y order by y::bigint limit 5) z;
    if jsonb_array_length(f.x->'finding_ids') > 5 then
      v_cite := coalesce(v_cite,'') || format('[+%s more]', jsonb_array_length(f.x->'finding_ids') - 5);
    end if;
    v_md := v_md || '- ' || (f.x->>'text') || ' ' || coalesce(v_cite,'');
    select string_agg('[E'||y||']', '' order by y::bigint) into v_cite from jsonb_array_elements_text(f.x->'evidence_ids') y;
    v_md := v_md || coalesce(v_cite,'') || E'\n';
  end loop;

  v_md := v_md || E'\n## What This Scan Did Not Check\n\n';
  for f in select x from jsonb_array_elements_text(v_scope) x loop
    v_md := v_md || '- ' || f.x || E'\n';
  end loop;

  v_md := v_md || format(E'\n## Findings\n\nShowing %s of %s open finding%s, most severe first.\n\n',
    v_shown, v_open, case when v_open = 1 then '' else 's' end);
  if v_shown = 0 then
    v_md := v_md || E'No findings are open against this site.\n';
  end if;
  for f in select x from jsonb_array_elements(v_top) x loop
    select string_agg('[E'||y||']', '' order by y::bigint) into v_cite from jsonb_array_elements_text(f.x->'evidence_ids') y;
    v_md := v_md || format('- **%s** (%s, `%s`): %s [F%s]%s',
      f.x->>'title', f.x->>'severity', f.x->>'rule_id', f.x->>'detail', f.x->>'finding_id', coalesce(v_cite,'')) || E'\n';
  end loop;

  v_md := v_md || E'\n## Plain English\n\n';
  if jsonb_array_length(v_plain) = 0 then
    v_md := v_md || E'No open findings. Keep scanning on schedule so this stays true.\n';
  end if;
  for f in select x from jsonb_array_elements(v_plain) x loop
    select string_agg('[E'||y||']', '' order by y::bigint) into v_cite from jsonb_array_elements_text(f.x->'evidence_ids') y;
    v_md := v_md || '- ' || (f.x->>'text') || ' [F' || (f.x->>'finding_id') || ']' || coalesce(v_cite,'') || E'\n';
  end loop;

  v_md := v_md || E'\n## Evidence Index\n\n| Evidence | Kind | URL | HTTP | SHA-256 |\n|---|---|---|---|---|\n';
  for f in select x from jsonb_array_elements(v_evidx) x loop
    v_md := v_md || format('| E%s | %s | %s | %s | %s |', f.x->>'evidence_id', f.x->>'kind', f.x->>'url', coalesce(f.x->>'http_status','n/a'), left(coalesce(f.x->>'sha256',''), 12)) || E'\n';
  end loop;

  update muster.sitreps set status = 'superseded' where website_id = v.website_id and status = 'final';
  select coalesce(max(version), 0) + 1 into v_version from muster.sitreps where scan_id = p_scan_id;

  insert into muster.sitreps (organization_id, website_id, scan_id, version, status, posture_score, posture_band, headline,
    sections, citations, content_md, content_sha256)
  values (v.organization_id, v.website_id, p_scan_id, v_version, 'final', v_score, v_band, left(v_headline, 300),
    jsonb_build_object(
      'scan', jsonb_build_object('scan_id', p_scan_id, 'target_url', v.target_url, 'final_url', v.final_url,
        'started_at', v.started_at, 'finished_at', v.finished_at, 'http_status', v.http_status, 'response_ms', v.response_ms,
        'engine_version', v.engine_version, 'summary', v.summary),
      'board_report', jsonb_build_object('headline', v_headline, 'posture_score', v_score, 'posture_band', v_band,
        'open', v_open, 'critical', v_crit, 'high', v_high, 'medium', v_med, 'low', v_low, 'info', v_info,
        'previous_score', v_prev, 'shown', v_shown, 'claims', v_claims),
      'scope_note', jsonb_build_object('items', v_scope),
      'plain_english', jsonb_build_object('items', v_plain),
      'top_findings', v_top,
      'jurisdiction', muster.q_sitrep_jurisdiction(v.website_id),
      'evidence_index', v_evidx),
    v_cites, v_md, encode(sha256(convert_to(v_md, 'utf8')), 'hex'))
  returning id into v_id;

  insert into muster.activity_events (organization_id, entity_type, entity_id, action, detail)
  values (v.organization_id, 'sitrep', v_id, 'SITREP generated', v_headline);

  return v_id;
end;
$function$;

do $$
declare
  v_sitrep bigint;
  v_open int;
  v_shown int;
  v_md text;
begin
  select count(*) into v_open from muster.findings where website_id = 11 and status in ('open','reopened');
  v_sitrep := muster.generate_sitrep(58);
  select jsonb_array_length(sections->'top_findings'), content_md into v_shown, v_md
    from muster.sitreps where id = v_sitrep;

  if v_shown <> v_open then
    raise exception 'report renders % findings but % are open', v_shown, v_open;
  end if;
  -- The trim must start at the lowest id, contiguously.
  if v_md not like '%[F305][F306][F307][F308][F309][+9 more]%' then
    raise exception 'the citation trim is not the first five by id';
  end if;
  if v_md like '%1 findings%' or v_md like '%1 open findings:%' then
    raise exception 'a singular count is still rendered as plural';
  end if;
  raise notice 'sitrep % ok: % of % findings', v_sitrep, v_shown, v_open;
end $$;
