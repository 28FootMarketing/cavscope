-- PRIV-004 (Terms of Service link, credited the way PRIV-001 credits a privacy
-- policy) and a per-website jurisdiction signal.
--
-- WHY: cavscope.q_sitrep_jurisdiction has always read country_code/region_code
-- from the ORGANIZATION that owns a website, never from the website itself.
-- That is right for a real tenant scanning its own site, and wrong for every
-- ad-hoc URL "Run a URL scan" parks in the admin sandbox org
-- (organizations.is_admin_sandbox): that org has ONE region_code (PA, After
-- Today LLC's own), so a YMCA actually in Hanover, PA and an unrelated SaaS
-- with no PA presence at all got the identical PA Act 35 citation in their
-- jurisdiction section -- a confident legal claim about a site the engine had
-- never asked anything about. supabase/functions/muster-scan/legal.ts (this
-- change's engine half, http-native-1.11.0, not yet deployed as of this
-- migration) reads a governing-law clause or postal address the site states
-- about ITSELF and reports it as detected_country_code/detected_region_code.
--
-- Column additions and the ingest/jurisdiction function updates below are
-- unconditionally safe to ship ahead of that deploy: a scan from the current
-- engine (which does not send these fields) writes null, coalesce falls back
-- to the organization's own code exactly as before, and nothing changes for
-- any website until it is actually rescanned by an engine that detects
-- something. PRIV-004 the CATALOG ROW is added inactive, per this repo's own
-- rule (never declare a rule active before there is live proof the engine
-- that emits it has deployed) -- same discipline as GOV-006..008 in migration
-- 20260923042421, activated only after that proof in 20260928164840.

alter table cavscope.websites
  add column if not exists detected_country_code char(2),
  add column if not exists detected_region_code varchar(8);

comment on column cavscope.websites.detected_country_code is
  'US only, for now. Read by the engine from a governing-law clause or postal address the site states about itself -- never guessed, never defaulted to the parking organization''s own jurisdiction. Null means not yet detected, not "same as the org."';
comment on column cavscope.websites.detected_region_code is
  'Two-letter US state code, same provenance and same null convention as detected_country_code.';

insert into cavscope.scan_rules (
  rule_id, category, title, description, default_severity, check_type,
  framework_refs, remediation, plain_english, active
) values (
  'PRIV-004', 'privacy',
  'No Terms of Service link found',
  'No link containing "terms" or "tos" was found on the homepage. Unlike a privacy policy, no privacy law requires a Terms of Service link on every homepage; this is a consumer-trust and contract-clarity signal, not a compliance mandate, which is why it is scored lower than PRIV-001.',
  'low', 'http_native',
  '{"CUSTOM":"Consumer contract terms"}'::jsonb,
  'Add a visible footer link to current Terms of Service (or Terms and Conditions) on every page.',
  'Visitors cannot find the terms they are agreeing to by using the site.',
  false
)
on conflict (rule_id) do nothing;

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

  -- Jurisdiction signal: a scan that detected a US state writes it onto the
  -- website. A scan that did not (old engine, or a site with no clause/address
  -- to read) leaves whatever the website already had -- never overwritten with
  -- a null, so a state detected on one scan is not erased by the next scan
  -- simply failing to re-detect it (a governing-law clause moving from the
  -- homepage to a page this engine did not follow, for instance).
  if (p_scan->>'detected_country_code') is not null then
    update cavscope.websites
       set detected_country_code = p_scan->>'detected_country_code',
           detected_region_code = p_scan->>'detected_region_code'
     where id = v_scan.website_id;
  end if;

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

-- q_sitrep_jurisdiction: prefer the WEBSITE's own detected jurisdiction over
-- the organization's, falling back to the organization's when the website has
-- not detected one (including every website scanned before this change).
create or replace function cavscope.q_sitrep_jurisdiction(p_website_id bigint)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to ''
as $function$
declare
  v_country text;
  v_region  text;
  v_adv     jsonb;
  v_laws    jsonb;
begin
  select coalesce(w.detected_country_code, o.country_code), coalesce(w.detected_region_code, o.region_code)
    into v_country, v_region
  from cavscope.websites w
  join cavscope.organizations o on o.id = w.organization_id
  where w.id = p_website_id;

  -- An organization with no jurisdiction recorded gets an explicit null rather
  -- than a guess. Defaulting to US here would put American statutes in front of
  -- a client who never said they were American.
  if v_country is null or v_country = '' then
    return jsonb_build_object('available', false,
      'reason', 'No country recorded for this organization, so no jurisdiction advisory can be given.');
  end if;

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
    'jurisdictions', coalesce(v_adv->'jurisdictions', '[]'::jsonb),
    'laws', v_laws,
    'law_count', jsonb_array_length(v_laws),
    'exposed_count', (select count(*) from jsonb_array_elements(v_laws) e where e->>'status' = 'exposed'),
    'attention_count', (select count(*) from jsonb_array_elements(v_laws) e where e->>'status' = 'attention'),
    'disclaimer', v_adv->'disclaimer');
end;
$function$;

do $$
declare v_n integer;
begin
  select count(*) into v_n from cavscope.scan_rules where rule_id = 'PRIV-004' and not active;
  if v_n <> 1 then
    raise exception 'expected PRIV-004 inserted inactive, found %', v_n;
  end if;

  select count(*) into v_n from information_schema.columns
   where table_schema = 'cavscope' and table_name = 'websites'
     and column_name in ('detected_country_code', 'detected_region_code');
  if v_n <> 2 then
    raise exception 'expected 2 new website columns, found %', v_n;
  end if;
end $$;
