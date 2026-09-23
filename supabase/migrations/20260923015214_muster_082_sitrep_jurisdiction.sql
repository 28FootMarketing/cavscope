-- MUSTER 082: the SITREP renders its jurisdiction section.
--
-- muster.q_sitrep_jurisdiction has run on every SITREP since migration 046 and its
-- output has been stored in sections.jurisdiction, where nothing rendered it: not
-- the markdown, not sitrep.html. For website 11 that was 13 laws scoped to US-PA,
-- 6 with open findings against them, carrying their own counsel disclaimer.
--
-- It could not simply be printed, because the payload's status has two values that
-- read as verdicts and one of them is not one. `clear` means "no open finding on a
-- mapped rule" -- and six of those thirteen laws (CAN-SPAM, TCPA, C2PA, ISO 42001,
-- the OECD principles, PA Act 35) map to no rule at all. Printed as-is, the report
-- would have said CAN-SPAM was clear on a scan that has no way to look at email
-- marketing. That is absence of findings read as a pass, which migration 062 exists
-- to prevent, in the one section most likely to be read as legal comfort.
--
-- So each law now carries an `assessment`, decided once here and stored, so the
-- markdown and the viewer cannot bucket it differently:
--
--   open_findings     a finding on a mapped rule is open (status exposed or attention)
--   no_open_findings  it maps to rules, and none of them is open
--   not_assessed      it maps to no rule, OR the scan read nothing (AVAIL-003/004),
--                     in which case every HTTP-derived rule produced nothing and
--                     "none open" would be the unread-target defect again
--
-- The wording is conditional throughout. Each law is shown with the condition under
-- which it applies (ADA Title II is for state and local government; COPPA for
-- sites directed to children), because a flat list of statute names under a
-- company's name reads as a determination that they apply. The disclaimer comes
-- from the payload, verbatim, and leads the section.
--
-- The generator is 078's, unchanged except for three lines: assess the payload
-- once, append the section before the Evidence Index, and store the assessed
-- payload instead of the raw one.

create or replace function muster.sitrep_jurisdiction_assess(p_jur jsonb, p_unread boolean)
 returns jsonb
 language sql
 immutable
 set search_path to ''
as $function$
  with laws as (
    select l || jsonb_build_object('assessment',
      case
        when l->>'status' in ('exposed', 'attention') then 'open_findings'
        when jsonb_array_length(coalesce(l->'rule_ids', '[]'::jsonb)) = 0 then 'not_assessed'
        when p_unread then 'not_assessed'
        else 'no_open_findings'
      end,
      'not_assessed_reason',
      case
        when l->>'status' in ('exposed', 'attention') then null
        when jsonb_array_length(coalesce(l->'rule_ids', '[]'::jsonb)) = 0 then 'no_mapped_check'
        when p_unread then 'scan_unread'
        else null
      end) as law
    from jsonb_array_elements(coalesce(p_jur->'laws', '[]'::jsonb)) l
  )
  select case
    when coalesce((p_jur->>'available')::boolean, false) is not true then p_jur
    else p_jur || jsonb_build_object(
      'laws', coalesce((select jsonb_agg(law order by law->>'short_name') from laws), '[]'::jsonb),
      'scan_unread', p_unread,
      'open_findings_count', (select count(*) from laws where law->>'assessment' = 'open_findings'),
      'no_open_findings_count', (select count(*) from laws where law->>'assessment' = 'no_open_findings'),
      'not_assessed_count', (select count(*) from laws where law->>'assessment' = 'not_assessed'))
  end;
$function$;

create or replace function muster.sitrep_jurisdiction_md(p_jur jsonb)
 returns text
 language plpgsql
 immutable
 set search_path to ''
as $function$
declare
  v_md    text;
  v_names jsonb;
  v_place text;
  l       record;
  f       record;
  n_open  integer := coalesce((p_jur->>'open_findings_count')::integer, 0);
  n_none  integer := coalesce((p_jur->>'no_open_findings_count')::integer, 0);
  n_na    integer := coalesce((p_jur->>'not_assessed_count')::integer, 0);
begin
  v_md := E'\n## Laws and Standards\n\n';

  if coalesce((p_jur->>'available')::boolean, false) is not true then
    return v_md || coalesce(p_jur->>'reason', 'No jurisdiction is recorded for this organization, so no laws are listed.') || E'\n';
  end if;

  select coalesce(jsonb_object_agg(j->>'code', j->>'name'), '{}'::jsonb) into v_names
    from jsonb_array_elements(coalesce(p_jur->'jurisdictions', '[]'::jsonb)) j;
  select string_agg(j->>'name', ', ' order by case j->>'kind' when 'region' then 0 when 'country' then 1 else 2 end)
    into v_place
    from jsonb_array_elements(coalesce(p_jur->'jurisdictions', '[]'::jsonb)) j
   where j->>'kind' in ('region', 'country');

  v_md := v_md || format(E'Location on record: %s. **%s**\n\n',
    coalesce(v_place, coalesce(p_jur->>'region_code', p_jur->>'country_code', 'not recorded')),
    coalesce(p_jur->>'disclaimer', 'Informational only. This is not legal advice. Confirm applicability with counsel.'));
  v_md := v_md || E'These are laws and standards commonly relevant to an organization in this location. Whether each one applies depends on facts this scan cannot see, such as who the site serves and what it collects, so each is shown with the condition under which it applies. A finding listed against a law means a check mapped to it is open. It is not a finding that the law was breached.\n';

  if n_open + n_none + n_na = 0 then
    return v_md || E'\nNo laws are recorded for this location.\n';
  end if;

  if n_open > 0 then
    v_md := v_md || format(E'\n### Open findings touch these (%s)\n\n', n_open);
    for l in select x from jsonb_array_elements(p_jur->'laws') x
              where x->>'assessment' = 'open_findings'
              order by (x->>'status' = 'exposed') desc, x->>'short_name' loop
      v_md := v_md || format(E'- **%s** (%s). %s\n  - Applies when: %s\n',
        l.x->>'short_name', coalesce(v_names->>(l.x->>'jurisdiction_code'), l.x->>'jurisdiction_code'),
        coalesce(l.x->>'summary', ''), coalesce(l.x->>'applies_when', 'not stated'));
      for f in select y from jsonb_array_elements(coalesce(l.x->'open_findings', '[]'::jsonb)) y loop
        v_md := v_md || format(E'  - Open: %s (%s, `%s`) [F%s]\n',
          f.y->>'title', f.y->>'severity', f.y->>'rule_id', f.y->>'finding_id');
      end loop;
      if l.x->>'reference_url' is not null then
        v_md := v_md || format(E'  - Reference: <%s>\n', l.x->>'reference_url');
      end if;
    end loop;
  end if;

  if n_none > 0 then
    v_md := v_md || format(E'\n### No open findings on the mapped checks (%s)\n\n', n_none);
    v_md := v_md || E'The checks MUSTER maps to these passed on this date. That is not a determination of compliance: each asks for more than a website scan can see.\n\n';
    for l in select x from jsonb_array_elements(p_jur->'laws') x
              where x->>'assessment' = 'no_open_findings' order by x->>'short_name' loop
      v_md := v_md || format(E'- **%s** (%s). Checks: %s. Applies when: %s\n',
        l.x->>'short_name', coalesce(v_names->>(l.x->>'jurisdiction_code'), l.x->>'jurisdiction_code'),
        (select string_agg('`' || r || '`', ', ' order by r) from jsonb_array_elements_text(l.x->'rule_ids') r),
        coalesce(l.x->>'applies_when', 'not stated'));
    end loop;
  end if;

  if n_na > 0 then
    v_md := v_md || format(E'\n### Not assessed by this scan (%s)\n\n', n_na);
    v_md := v_md || E'This report says nothing about these either way. They are listed because they are commonly relevant here.';
    if coalesce((p_jur->>'scan_unread')::boolean, false) then
      v_md := v_md || E' On this scan the engine did not read the page, so laws whose checks depend on it are listed here rather than as passed.';
    end if;
    v_md := v_md || E'\n\n';
    for l in select x from jsonb_array_elements(p_jur->'laws') x
              where x->>'assessment' = 'not_assessed' order by x->>'short_name' loop
      v_md := v_md || format(E'- **%s** (%s). %s Applies when: %s\n',
        l.x->>'short_name', coalesce(v_names->>(l.x->>'jurisdiction_code'), l.x->>'jurisdiction_code'),
        case l.x->>'not_assessed_reason'
          when 'no_mapped_check' then 'No MUSTER check maps to it.'
          else 'Its checks could not run on this scan.'
        end,
        coalesce(l.x->>'applies_when', 'not stated'));
    end loop;
  end if;

  return v_md;
end;
$function$;

revoke all on function muster.sitrep_jurisdiction_assess(jsonb, boolean) from public, anon, authenticated;
revoke all on function muster.sitrep_jurisdiction_md(jsonb) from public, anon, authenticated;

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
  v_jur     jsonb;
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

  -- Assessed once, here, and stored: the markdown and the viewer both read the
  -- per-law `assessment`, so they cannot bucket a law differently.
  v_jur := muster.sitrep_jurisdiction_assess(muster.q_sitrep_jurisdiction(v.website_id), coalesce(v_unread, false));

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

  v_md := v_md || muster.sitrep_jurisdiction_md(v_jur);

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
      'jurisdiction', v_jur,
      'evidence_index', v_evidx),
    v_cites, v_md, encode(sha256(convert_to(v_md, 'utf8')), 'hex'))
  returning id into v_id;

  insert into muster.activity_events (organization_id, entity_type, entity_id, action, detail)
  values (v.organization_id, 'sitrep', v_id, 'SITREP generated', v_headline);

  return v_id;
end;
$function$;

-- Assertions against live data. Scan 90 is website 11 (Hanover Area YMCA) in the
-- admin sandbox org, nobody's register, and the site whose payload found the defect.
do $$
declare
  v_sitrep bigint;
  v_md text;
  v_jur jsonb;
  v_open int;
  v_shown int;
  v_bad text;
  v_unread jsonb;
begin
  select count(*) into v_open from muster.findings where website_id = 11 and status in ('open','reopened');
  v_sitrep := muster.generate_sitrep(90);
  select content_md, sections->'jurisdiction', jsonb_array_length(sections->'top_findings')
    into v_md, v_jur, v_shown from muster.sitreps where id = v_sitrep;

  -- 078's contract still holds.
  if v_shown <> v_open then
    raise exception 'report renders % findings but % are open', v_shown, v_open;
  end if;

  -- Every law is assessed, and the three buckets account for all of them.
  select string_agg(x->>'short_name', ', ') into v_bad
    from jsonb_array_elements(v_jur->'laws') x where x->>'assessment' is null;
  if v_bad is not null then raise exception 'unassessed laws: %', v_bad; end if;
  if (v_jur->>'open_findings_count')::int + (v_jur->>'no_open_findings_count')::int
     + (v_jur->>'not_assessed_count')::int <> (v_jur->>'law_count')::int then
    raise exception 'buckets do not account for every law';
  end if;

  -- The defect itself: a law with no mapped check is never "no open findings".
  select string_agg(x->>'short_name', ', ') into v_bad
    from jsonb_array_elements(v_jur->'laws') x
   where x->>'assessment' = 'no_open_findings'
     and jsonb_array_length(coalesce(x->'rule_ids', '[]'::jsonb)) = 0;
  if v_bad is not null then raise exception 'reported as passed with no mapped check: %', v_bad; end if;

  -- And an unread scan passes nothing.
  v_unread := muster.sitrep_jurisdiction_assess(muster.q_sitrep_jurisdiction(11), true);
  if (v_unread->>'no_open_findings_count')::int <> 0 then
    raise exception 'an unread scan reported % laws with no open findings', v_unread->>'no_open_findings_count';
  end if;

  -- The markdown carries the section, the disclaimer verbatim, and puts CAN-SPAM
  -- (no mapped check) under not assessed and FTC Act Section 5 (mapped, nothing
  -- open) under the mapped heading -- by position, not just presence.
  if v_md not like '%## Laws and Standards%' then raise exception 'section missing'; end if;
  if position(v_jur->>'disclaimer' in v_md) = 0 then raise exception 'disclaimer missing'; end if;
  if position('**CAN-SPAM**' in v_md) < position('### Not assessed by this scan' in v_md)
     or position('### Not assessed by this scan' in v_md) = 0 then
    raise exception 'CAN-SPAM is not under Not assessed';
  end if;
  if position('**FTC Act Section 5**' in v_md) < position('### No open findings on the mapped checks' in v_md)
     or position('**FTC Act Section 5**' in v_md) > position('### Not assessed by this scan' in v_md) then
    raise exception 'FTC Act Section 5 is not under the mapped heading';
  end if;
  -- Before the Evidence Index, after Plain English.
  if not (position('## Plain English' in v_md) < position('## Laws and Standards' in v_md)
          and position('## Laws and Standards' in v_md) < position('## Evidence Index' in v_md)) then
    raise exception 'section is out of order';
  end if;

  raise notice 'sitrep % ok: % open / % mapped-clear / % not assessed of % laws', v_sitrep,
    v_jur->>'open_findings_count', v_jur->>'no_open_findings_count', v_jur->>'not_assessed_count', v_jur->>'law_count';
end $$;
