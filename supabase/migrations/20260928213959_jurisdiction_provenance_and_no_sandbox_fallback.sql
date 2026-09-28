-- Records where every jurisdiction detection came from, and stops sandbox
-- sites falling back to the sandbox organization's own state.
--
-- 1. PROVENANCE. Engine http-native-1.15.0 sends detected_region_basis
--    (governing_law / jsonld_address / postal_address / meta_description)
--    and detected_region_source (the URL it was read from) with every
--    detection. A governing-law clause is the site making a legal claim; a
--    meta description is ad copy. Until now the report printed both as the
--    same unqualified "Location on record", so a guess read with the
--    confidence of a clause. q_sitrep_jurisdiction now emits
--    location_source {origin, basis, source_url, note}, and every renderer
--    prints the note verbatim: the words are decided once, here, so the
--    markdown, sitrep.html and app.html cannot describe the same location
--    differently.
--
-- 2. NO SANDBOX FALLBACK. A site with no detected state fell back to its
--    organization's country_code/region_code. For a real tenant that is the
--    tenant's own declared location and remains the right fallback. For a
--    site parked in the admin sandbox org (organizations.is_admin_sandbox)
--    it is After Today LLC's own Pennsylvania address, which says nothing
--    about the site: studyfetch.com and plansync.io were being listed under
--    Pennsylvania law on that basis alone. That is the defect migration
--    20260928170144 set out to fix, narrowed rather than removed. A sandbox
--    site with nothing detected is now available:false with a reason saying
--    no location was detected and none is assumed.
--
-- Rows detected before 1.15.0 have no basis; their note says only that the
-- location was read from the site, and the next scan fills it in.

alter table cavscope.websites
  add column if not exists detected_region_basis text,
  add column if not exists detected_region_source text;

alter table cavscope.websites drop constraint if exists websites_detected_region_basis_check;
alter table cavscope.websites add constraint websites_detected_region_basis_check
  check (detected_region_basis is null
         or detected_region_basis in ('governing_law', 'jsonld_address', 'postal_address', 'meta_description'));

comment on column cavscope.websites.detected_region_basis is
  'Which signal detected_region_code was read from, strongest first: governing_law, jsonld_address, postal_address, meta_description. Null when nothing was detected, or when detected by an engine older than http-native-1.15.0.';
comment on column cavscope.websites.detected_region_source is
  'The URL detected_region_code was read from: the homepage or one same-origin legal/about/contact page.';

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
         detected_region_code = p_scan->>'detected_region_code',
         detected_region_basis = p_scan->>'detected_region_basis',
         detected_region_source = left(p_scan->>'detected_region_source', 2048)
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

create or replace function cavscope.q_sitrep_jurisdiction(p_website_id bigint)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to ''
as $function$
declare
  v_country  text;
  v_region   text;
  v_detected boolean;
  v_basis    text;
  v_source   text;
  v_sandbox  boolean;
  v_note     text;
  v_origin   jsonb;
  v_adv      jsonb;
  v_laws     jsonb;
begin
  select coalesce(w.detected_country_code, o.country_code), coalesce(w.detected_region_code, o.region_code),
         w.detected_region_code is not null, w.detected_region_basis, w.detected_region_source,
         coalesce(o.is_admin_sandbox, false)
    into v_country, v_region, v_detected, v_basis, v_source, v_sandbox
  from cavscope.websites w
  join cavscope.organizations o on o.id = w.organization_id
  where w.id = p_website_id;

  -- A sandbox org's location is the scanning workspace's, never the site's.
  -- With nothing detected there is no location to report, so none is assumed.
  if not v_detected and v_sandbox then
    return jsonb_build_object('available', false,
      'reason', 'This site states no location CavScope could detect (no governing-law clause, no postal address in its structured data or text, and no state named in its description), and it was scanned as an ad-hoc audit, not for an organization with a location on record. No jurisdiction is assumed, so no laws are listed.',
      'location_source', jsonb_build_object('origin', 'none'));
  end if;

  -- An organization with no jurisdiction recorded gets an explicit null rather
  -- than a guess. Defaulting to US here would put American statutes in front of
  -- a client who never said they were American.
  if v_country is null or v_country = '' then
    return jsonb_build_object('available', false,
      'reason', 'No country recorded for this organization, so no jurisdiction advisory can be given.');
  end if;

  v_note := case
    when v_detected and v_basis = 'governing_law'    then 'Read from this site''s own governing-law clause.'
    when v_detected and v_basis = 'jsonld_address'   then 'Read from the postal address in this site''s structured data.'
    when v_detected and v_basis = 'postal_address'   then 'Read from a postal address printed on this site.'
    when v_detected and v_basis = 'meta_description' then 'Read from a state named in this site''s description. That is the weakest signal CavScope uses: marketing copy often names where a business works rather than where it is based.'
    when v_detected                                  then 'Read from this site.'
    else 'Taken from this organization''s own record. The site itself states no location CavScope could detect.'
  end;
  v_origin := jsonb_build_object(
    'origin', case when v_detected then 'website' else 'organization' end,
    'basis', v_basis,
    'source_url', case when v_detected then v_source end,
    'note', v_note);

  v_adv := cavscope.q_jurisdiction_advisory(v_country, v_region, true);

  select coalesce(jsonb_agg(law order by law->>'short_name'), '[]'::jsonb)
  into v_laws
  from (
    select l || jsonb_build_object(
      'open_findings', coalesce(f.open_findings, '[]'::jsonb),
      'status', case
                  when coalesce(f.bad, 0) > 0 then 'exposed'
                  when coalesce(f.soft, 0) > 0 then 'attention'
                  else 'clear'
                end
    ) as law
    from jsonb_array_elements(coalesce(v_adv->'laws', '[]'::jsonb)) as l
    left join lateral (
      select
        jsonb_agg(jsonb_build_object(
          'finding_id', fi.id, 'rule_id', fi.rule_id,
          'severity', fi.severity, 'title', fi.title)
          order by cavscope.severity_rank(fi.severity), fi.rule_id) as open_findings,
        count(*) filter (where fi.severity in ('critical','high')) as bad,
        count(*) filter (where fi.severity in ('medium','low'))    as soft
      from cavscope.findings fi
      where fi.website_id = p_website_id
        and fi.status in ('open','reopened')
        and fi.rule_id::text in (
          select jsonb_array_elements_text(coalesce(l->'rule_ids', '[]'::jsonb))
        )
    ) f on true
  ) x;

  return jsonb_build_object(
    'available', true,
    'country_code', v_adv->'country_code',
    'region_code', v_adv->'region_code',
    'location_source', v_origin,
    'jurisdictions', coalesce(v_adv->'jurisdictions', '[]'::jsonb),
    'laws', v_laws,
    'law_count', jsonb_array_length(v_laws),
    'exposed_count', (select count(*) from jsonb_array_elements(v_laws) e where e->>'status' = 'exposed'),
    'attention_count', (select count(*) from jsonb_array_elements(v_laws) e where e->>'status' = 'attention'),
    'disclaimer', v_adv->'disclaimer');
end;
$function$;

-- sitrep_jurisdiction_md: print location_source.note after "Location on
-- record". Patched in place rather than redefined from a file, because the
-- live definition has drifted from its only file (082): a branding migration
-- rewrote its prose in place, and re-creating it from 082 would silently undo
-- that. Insert-only, at an anchor asserted to occur exactly once.
do $$
declare
  v_def    text;
  v_anchor text := $a$  v_md := v_md || E'These are laws and standards commonly relevant$a$;
  v_ins    text := $i$  if p_jur->'location_source'->>'note' is not null then
    v_md := v_md || (p_jur->'location_source'->>'note')
      || case when p_jur->'location_source'->>'source_url' ~* '^https?://'
              then format(' Source: <%s>', p_jur->'location_source'->>'source_url') else '' end
      || E'\n\n';
  end if;
$i$;
  v_new    text;
begin
  select pg_get_functiondef('cavscope.sitrep_jurisdiction_md(jsonb)'::regprocedure) into v_def;
  if (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor) <> 1 then
    raise exception 'sitrep_jurisdiction_md: anchor not found exactly once; refusing to patch';
  end if;
  if position('location_source' in v_def) > 0 then
    raise exception 'sitrep_jurisdiction_md already prints location_source; refusing to patch twice';
  end if;
  v_new := replace(v_def, v_anchor, v_ins || v_anchor);
  execute v_new;
end $$;

do $$
declare v_n integer; v_def text; v_out jsonb;
begin
  select count(*) into v_n from information_schema.columns
   where table_schema = 'cavscope' and table_name = 'websites'
     and column_name in ('detected_region_basis', 'detected_region_source');
  if v_n <> 2 then raise exception 'expected 2 new website columns, found %', v_n; end if;

  select pg_get_functiondef('cavscope.sitrep_jurisdiction_md(jsonb)'::regprocedure) into v_def;
  if position('location_source' in v_def) = 0 then raise exception 'markdown does not print location_source'; end if;

  -- A sandbox site with nothing detected no longer inherits the sandbox org's state.
  select cavscope.q_sitrep_jurisdiction(w.id) into v_out
    from cavscope.websites w join cavscope.organizations o on o.id = w.organization_id
   where o.is_admin_sandbox and w.detected_region_code is null limit 1;
  if v_out is not null and (v_out->>'available')::boolean then
    raise exception 'a sandbox site with no detected state still resolved a jurisdiction: %', v_out->>'region_code';
  end if;

  -- A detected one says where its location came from.
  select cavscope.q_sitrep_jurisdiction(w.id) into v_out
    from cavscope.websites w where w.detected_region_code is not null limit 1;
  if v_out is not null and v_out->'location_source'->>'note' is null then
    raise exception 'a detected site carries no location_source note';
  end if;
end $$;
