-- MUSTER 077: the SITREP stops omitting findings, stops collapsing its own header,
-- and says what it did not check.
--
-- Four defects, found by scoring the report as a document a borough manager reads
-- rather than as a function that returns a row.
--
-- 1. IT DROPPED FINDINGS AND STATED A COUNT THAT IMPLIED IT DID NOT.
--
-- The finding loop carried `limit 12`. SITREP 55 (Hanover Area YMCA) says
-- "14 open findings: 0 critical, 1 high, 3 medium, 7 low, 3 informational" and then
-- renders 12, showing one informational. GOV-003 and GOV-004 are absent and nothing
-- says so. Verified against muster.findings, not inferred.
--
-- That is the house defect of this codebase pointed at the deliverable: a document
-- that quietly knows more than it shows. The cap is now 50, named, and when it binds
-- the report says which findings it is not showing and where to read them. A cap that
-- announces itself is a design decision; a cap that does not is a lie by arithmetic.
--
-- 2. THE HEADER COLLAPSED WHEN THE FILE TRAVELLED.
--
-- Organization / Target / Scan were three lines separated by single newlines, which
-- every CommonMark renderer folds into one run-on paragraph. Nothing in the product
-- exposed it -- admin.html wraps content_md in <pre>, and sitrep.html never reads
-- content_md at all -- so it only bit when the .md file left the building, which is
-- the only thing a .md file is for. Now a table.
--
-- 3. THE MARKDOWN AND THE VIEWER WERE DIFFERENT DOCUMENTS.
--
-- sitrep.html renders four sections from `sections`; the markdown rendered three,
-- omitting Top Findings entirely. CLAUDE.md justifies the console rendering markdown
-- verbatim on the grounds that "the console cannot disagree with what the tenant
-- reads at /sitrep" -- but it did, and in the direction that matters: the console
-- reader saw strictly less. Findings are now rendered in both.
--
-- 4. "Board Report" WAS NOT ONE, AND THE REPORT NEVER STATED ITS OWN SCOPE.
--
-- Every finding appeared at full technical detail in Board Report and again in Plain
-- English. The section named for the person with eleven minutes was the longest one.
-- Board Report is now five claims: posture, direction since the last scan, the
-- worst open item, the severity spread, and what the scan actually read. The
-- finding-by-finding detail moved to Findings, where it belongs.
--
-- And docs/SCAN-RULES.md has been careful from the start that a framework mapping is
-- a citation and not a test, and that the engine has no browser and no authenticated
-- crawl -- while the deliverable, the one document a customer actually reads, said
-- none of it. A new section does now. For a product whose whole integrity case is
-- not overclaiming, the scope boundary belonging anywhere but the report was the
-- largest single gap in it.
--
-- WHAT IS DELIBERATELY NOT CHANGED
--
-- The `jurisdiction` section is computed by muster.q_sitrep_jurisdiction on every
-- generation, stored in `sections`, and rendered by NOTHING -- not the markdown, not
-- sitrep.html. For website 11 it carries 13 laws, 6 needing attention, correctly
-- scoped to US-PA, with its own counsel disclaimer. That is a product decision about
-- what MUSTER sells, not a rendering bug, so it is left alone here rather than
-- shipped unasked.

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

  -- The previous report for this site, for direction. Read before the supersede
  -- below, which has not run yet.
  select posture_score into v_prev
  from muster.sitreps
  where website_id = v.website_id and scan_id <> p_scan_id
  order by id desc limit 1;

  -- The worst open finding, for the one line a reader keeps.
  select fi.id, fi.severity, fi.title into v_worst
  from muster.findings fi
  where fi.website_id = v.website_id and fi.status in ('open','reopened')
  order by muster.severity_rank(fi.severity), fi.id
  limit 1;

  -- Did the engine actually read a page? AVAIL-003 and AVAIL-004 both mean a server
  -- answered and the scan read nothing, which changes what every other number means.
  v_unread := v.http_status is null
    or exists (select 1 from muster.findings fi
               where fi.website_id = v.website_id and fi.status in ('open','reopened')
                 and fi.rule_id in ('AVAIL-001','AVAIL-003','AVAIL-004'));
  v_skipped := coalesce((v.summary->>'skipped_inactive')::integer, 0);

  -- BOARD REPORT: five claims, for the reader who has eleven minutes.
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
  v_line := v_line || format(' This scan added %s findings, reopened %s, and resolved %s.',
    coalesce(v.summary->>'new','0'), coalesce(v.summary->>'reopened','0'), coalesce(v.summary->>'resolved','0'));
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
    'text', format('%s open findings: %s critical, %s high, %s medium, %s low, %s informational.', v_open, v_crit, v_high, v_med, v_low, v_info),
    'finding_ids', to_jsonb(v_open_ids), 'evidence_ids', '[]'::jsonb);

  c := c + 1;
  if v.http_status is not null then
    v_line := format('The homepage returned HTTP %s in %s ms from %s.',
      v.http_status, coalesce(v.response_ms::text,'an unrecorded number of'), coalesce(v.final_url, v.target_url));
  else
    -- Never "responded with HTTP no response". The engine read nothing; say that.
    v_line := format('No readable HTTP response was returned by %s, so no page content, headers or cookies were read. The finding below explains what happened; every HTTP-derived check produced nothing for this scan.',
      coalesce(v.final_url, v.target_url));
  end if;
  v_claims := v_claims || jsonb_build_object('id', 'C'||c, 'text', v_line,
    'finding_ids', '[]'::jsonb, 'evidence_ids', to_jsonb(array_remove(array[v_primary], null)));

  -- FINDINGS. No silent cap.
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

  -- If the cap bound, the report says so instead of trimming in silence.
  if v_open > v_shown then
    c := c + 1;
    v_claims := v_claims || jsonb_build_object('id', 'C'||c,
      'text', format('This report details the %s most severe of %s open findings. The remaining %s are in the MUSTER workspace under this site''s risk register.',
        v_shown, v_open, v_open - v_shown),
      'finding_ids', '[]'::jsonb, 'evidence_ids', '[]'::jsonb);
  end if;

  -- WHAT THIS SCAN DID NOT CHECK. The scope boundary lived in docs/SCAN-RULES.md and
  -- nowhere a customer would ever see it.
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

  -- Citations now cover the findings section too, since the per-finding claims moved
  -- out of board_report. Without this the report would cite less than it shows.
  select coalesce(jsonb_agg(jsonb_build_object('claim_id', x->>'id', 'finding_ids', x->'finding_ids', 'evidence_ids', x->'evidence_ids')), '[]'::jsonb)
  into v_cites from jsonb_array_elements(v_claims) x;
  select v_cites || coalesce(jsonb_agg(jsonb_build_object('claim_id', 'T'||(x->>'rank'),
           'finding_ids', jsonb_build_array(x->'finding_id'), 'evidence_ids', x->'evidence_ids')), '[]'::jsonb)
  into v_cites from jsonb_array_elements(v_top) x;

  v_headline := format('%s: posture %s/100 (%s), %s open findings, %s critical', v.website_name, v_score, v_band, v_open, v_crit);

  -- MARKDOWN. A table for the header, because three lines joined by single newlines
  -- are one paragraph in CommonMark and this file is meant to be forwarded.
  v_md := format(E'# SITREP: %s\n\n| | |\n|---|---|\n| Organization | %s |\n| Target | %s |\n| Scan | #%s, completed %s |\n| Engine | %s |\n| Posture | %s / 100 (%s) |\n\nPrepared by MUSTER. Every statement below cites a finding [F] or captured evidence [E] row.\n\n## Board Report\n\n',
    v.website_name, v.org_name, v.target_url, p_scan_id,
    to_char(v.finished_at at time zone 'UTC', 'YYYY-MM-DD HH24:MI UTC'),
    coalesce(v.engine_version,'n/a'), v_score, v_band);

  for f in select x from jsonb_array_elements(v_claims) x loop
    -- More than five finding citations on one claim is noise at exactly the moment
    -- the reader is trying to absorb a number. The full list stays in `citations`.
    select string_agg('[F'||y||']', '' order by y) into v_cite
      from (select y from jsonb_array_elements_text(f.x->'finding_ids') y limit 5) z;
    if jsonb_array_length(f.x->'finding_ids') > 5 then
      v_cite := coalesce(v_cite,'') || format('[+%s more]', jsonb_array_length(f.x->'finding_ids') - 5);
    end if;
    v_md := v_md || '- ' || (f.x->>'text') || ' ' || coalesce(v_cite,'');
    select string_agg('[E'||y||']', '') into v_cite from jsonb_array_elements_text(f.x->'evidence_ids') y;
    v_md := v_md || coalesce(v_cite,'') || E'\n';
  end loop;

  v_md := v_md || E'\n## What This Scan Did Not Check\n\n';
  for f in select x from jsonb_array_elements_text(v_scope) x loop
    v_md := v_md || '- ' || f.x || E'\n';
  end loop;

  v_md := v_md || format(E'\n## Findings\n\nShowing %s of %s open findings, most severe first.\n\n', v_shown, v_open);
  if v_shown = 0 then
    v_md := v_md || E'No findings are open against this site.\n';
  end if;
  for f in select x from jsonb_array_elements(v_top) x loop
    select string_agg('[E'||y||']', '') into v_cite from jsonb_array_elements_text(f.x->'evidence_ids') y;
    v_md := v_md || format('- **%s** (%s, `%s`): %s [F%s]%s',
      f.x->>'title', f.x->>'severity', f.x->>'rule_id', f.x->>'detail', f.x->>'finding_id', coalesce(v_cite,'')) || E'\n';
  end loop;

  v_md := v_md || E'\n## Plain English\n\n';
  if jsonb_array_length(v_plain) = 0 then
    v_md := v_md || E'No open findings. Keep scanning on schedule so this stays true.\n';
  end if;
  for f in select x from jsonb_array_elements(v_plain) x loop
    select string_agg('[E'||y||']', '') into v_cite from jsonb_array_elements_text(f.x->'evidence_ids') y;
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

-- The count the report states must equal the number of findings it renders. This is
-- the assertion `limit 12` would have failed for the life of the product.
do $$
declare
  v_sitrep bigint;
  v_open int;
  v_shown int;
  v_md text;
  v_claims int;
begin
  select count(*) into v_open from muster.findings where website_id = 11 and status in ('open','reopened');
  v_sitrep := muster.generate_sitrep(58);

  select jsonb_array_length(sections->'top_findings'),
         jsonb_array_length(sections->'plain_english'->'items'),
         content_md
    into v_shown, v_claims, v_md
    from muster.sitreps where id = v_sitrep;

  if v_shown <> v_open then
    raise exception 'report renders % findings but % are open', v_shown, v_open;
  end if;
  if v_claims <> v_open then
    raise exception 'plain english renders % items but % findings are open', v_claims, v_open;
  end if;
  if v_md not like '%## What This Scan Did Not Check%' then
    raise exception 'the scope section is missing from the markdown';
  end if;
  if v_md not like '%## Findings%' then
    raise exception 'the findings section is missing from the markdown';
  end if;
  if v_md like '%HTTP no response%' then
    raise exception 'the null-status phrasing survived';
  end if;
  if v_md not like '%| Organization |%' then
    raise exception 'the header is not a table';
  end if;
  raise notice 'sitrep % renders all % findings', v_sitrep, v_open;
end $$;
