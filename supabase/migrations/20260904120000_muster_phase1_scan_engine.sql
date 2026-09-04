-- MUSTER phase 1: scan engine
-- Project: mgtmqucaldkaxvxglguw (shared 28FS project), schema: muster
-- Adds scan rules, scan runs, captured evidence, deduplicated findings, and SITREPs.
-- Every SITREP claim cites finding ids and scan_evidence ids. No claim without a row.

-- Stale search_path left over from the sentinel -> muster rename.
alter function muster.touch_updated_at() set search_path = 'muster', 'pg_temp';

------------------------------------------------------------------------------
-- Rule catalog
------------------------------------------------------------------------------
create table if not exists muster.scan_rules (
  rule_id           text primary key,
  category          varchar(32) not null
                    check (category in ('security','privacy','accessibility','availability','third_party','governance')),
  title             varchar(200) not null,
  description       text not null,
  default_severity  varchar(16) not null
                    check (default_severity in ('critical','high','medium','low','info')),
  check_type        varchar(16) not null default 'http_native'
                    check (check_type in ('http_native','browser','manual')),
  framework_refs    jsonb not null default '{}'::jsonb,
  remediation       text not null,
  plain_english     text not null,
  active            boolean not null default true,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create or replace trigger scan_rules_touch before update on muster.scan_rules
  for each row execute function muster.touch_updated_at();

insert into muster.scan_rules (rule_id, category, title, description, default_severity, framework_refs, remediation, plain_english) values
('AVAIL-001','availability','Site unreachable or returning an error','The homepage did not return a successful (2xx) response.','critical','{"NIST_CSF":"DE.CM-1","SOC_2":"A1.2"}','Confirm DNS, hosting, and TLS certificate. Check origin and CDN status pages. Restore service before any other remediation.','Visitors cannot load the site. Nothing else matters until this is fixed.'),
('AVAIL-002','availability','Slow first response','The homepage took longer than 3 seconds to return its first response.','medium','{"NIST_CSF":"PR.DS-4"}','Enable caching or a CDN, reduce server-side work on the homepage, and check hosting capacity.','The site is slow to start loading. Slow sites lose visitors and rank lower in search.'),
('SEC-001','security','HTTP does not redirect to HTTPS','A request over plain HTTP was served without redirecting to HTTPS.','high','{"NIST_CSF":"PR.DS-2","PCI_DSS":"4.2.1"}','Configure a permanent (301/308) redirect from http:// to https:// at the CDN or web server.','Visitors who type the address without https can be intercepted. Force the secure version.'),
('SEC-002','security','Missing Strict-Transport-Security header','The HTTPS response did not include an HSTS header.','medium','{"NIST_CSF":"PR.DS-2"}','Add Strict-Transport-Security: max-age=31536000; includeSubDomains after confirming every subdomain serves HTTPS.','Browsers are not told to always use the secure connection. One header fixes it.'),
('SEC-003','security','Weak HSTS max-age','HSTS max-age is below 180 days.','low','{"NIST_CSF":"PR.DS-2"}','Raise max-age to at least 15552000 seconds (180 days), ideally 31536000.','The secure-connection instruction expires too quickly.'),
('SEC-004','security','Missing Content-Security-Policy','No Content-Security-Policy header was returned.','medium','{"NIST_CSF":"PR.PT-3","SOC_2":"CC6.6"}','Publish a CSP. Start in report-only mode, then enforce script-src and object-src restrictions.','There is no policy limiting which scripts can run on the page. This is the main defense against injected code.'),
('SEC-005','security','Clickjacking protection missing','Neither X-Frame-Options nor a CSP frame-ancestors directive was present.','medium','{"NIST_CSF":"PR.PT-3"}','Add Content-Security-Policy: frame-ancestors ''self'' or X-Frame-Options: SAMEORIGIN.','Another site could load your pages inside a hidden frame to trick visitors into clicking.'),
('SEC-006','security','Missing X-Content-Type-Options','The nosniff header was not present.','low','{"NIST_CSF":"PR.PT-3"}','Add X-Content-Type-Options: nosniff.','Browsers may guess file types, which can turn harmless files into executable code.'),
('SEC-007','security','Missing Referrer-Policy','No Referrer-Policy header was present.','low','{"NIST_CSF":"PR.DS-5"}','Add Referrer-Policy: strict-origin-when-cross-origin.','Full page addresses may leak to other sites when visitors click outbound links.'),
('SEC-008','security','Missing Permissions-Policy','No Permissions-Policy header was present.','low','{"NIST_CSF":"PR.PT-3"}','Add Permissions-Policy disabling camera, microphone, geolocation, and payment unless used.','Browser features like camera and location are not explicitly restricted.'),
('SEC-009','security','Server software version disclosed','A Server or X-Powered-By header exposes software and version details.','low','{"NIST_CSF":"PR.IP-1"}','Remove or genericize Server and X-Powered-By headers at the web server or CDN.','The site advertises what software it runs, which helps attackers pick exploits.'),
('SEC-010','security','Mixed content on an HTTPS page','The HTTPS page loads scripts, styles, frames, or media over plain HTTP.','high','{"NIST_CSF":"PR.DS-2"}','Change every http:// resource reference to https:// or a protocol-relative path.','Some parts of the secure page are loaded insecurely, which browsers block or warn about.'),
('SEC-011','security','Cookie set without protective flags','A Set-Cookie header is missing Secure, HttpOnly, or SameSite.','medium','{"NIST_CSF":"PR.DS-1","SOC_2":"CC6.1"}','Set Secure; HttpOnly; SameSite=Lax (or Strict) on session and auth cookies.','Login cookies could be read or replayed by scripts or other sites.'),
('SEC-012','security','No security.txt disclosure policy','No /.well-known/security.txt file was found.','low','{"ISO_27001":"A.5.5","NIST_CSF":"RS.CO-1"}','Publish /.well-known/security.txt with Contact and Expires fields per RFC 9116.','Researchers who find a vulnerability have no published way to report it to you.'),
('SEC-013','security','Final page served over HTTP','After following redirects the homepage was served over plain HTTP.','critical','{"NIST_CSF":"PR.DS-2","PCI_DSS":"4.2.1"}','Install a TLS certificate and serve the site only over HTTPS.','The site itself is not encrypted. Anything visitors type can be read in transit.'),
('PRIV-001','privacy','No privacy policy link found','No link containing "privacy" was found on the homepage.','medium','{"GDPR":"Art. 13","CUSTOM":"CCPA 1798.130, CalOPPA"}','Add a visible footer link to a current privacy policy on every page.','Visitors cannot find how their data is used. Most privacy laws require this link.'),
('PRIV-002','privacy','Third-party trackers loaded before consent could be verified','Known analytics or advertising trackers are loaded by the homepage.','low','{"GDPR":"Art. 6, Art. 7","CUSTOM":"ePrivacy, CCPA opt-out"}','Confirm a consent mechanism gates these scripts where required, and list them in the privacy policy.','The site uses tracking tools. Depending on where visitors live, consent may be required first.'),
('PRIV-003','privacy','Form submits to an insecure or external endpoint','A form action posts over HTTP or to a different domain.','medium','{"GDPR":"Art. 32","NIST_CSF":"PR.DS-2"}','Post forms over HTTPS and document any third-party form processor in the privacy policy.','Information typed into a form may travel unencrypted or to a vendor visitors do not know about.'),
('TP-001','third_party','External script inventory','Scripts are loaded from third-party hosts. Each is a supply-chain dependency.','info','{"NIST_CSF":"ID.SC-2","SOC_2":"CC9.2"}','Review each host, remove unused scripts, and add Subresource Integrity where supported.','These are the outside companies whose code runs on your site. Keep the list short and known.'),
('A11Y-001','accessibility','Page language not declared','The html element has no lang attribute.','medium','{"WCAG":"3.1.1"}','Add lang="en" (or the correct language code) to the html element.','Screen readers do not know which language to use, so pronunciation is wrong.'),
('A11Y-002','accessibility','Page title missing or empty','No non-empty title element was found.','medium','{"WCAG":"2.4.2"}','Add a descriptive title element that names the page and the site.','The browser tab and screen readers have no name for this page.'),
('A11Y-003','accessibility','Images missing alternative text','One or more img elements have no alt attribute.','medium','{"WCAG":"1.1.1"}','Add alt text describing each meaningful image. Use alt="" for purely decorative images.','People using screen readers cannot tell what these images show.'),
('A11Y-004','accessibility','Pinch zoom disabled','The viewport meta tag blocks user scaling.','medium','{"WCAG":"1.4.4"}','Remove user-scalable=no and any maximum-scale below 2 from the viewport meta tag.','Visitors with low vision cannot zoom the page on their phone.'),
('A11Y-005','accessibility','No top-level heading','No h1 element was found.','low','{"WCAG":"2.4.6"}','Add a single h1 that describes the page.','The page has no main heading, which makes it harder to navigate by assistive technology.'),
('A11Y-006','accessibility','Form fields without an accessible label','Inputs were found with no associated label, aria-label, or aria-labelledby.','medium','{"WCAG":"1.3.1","CUSTOM":"WCAG 4.1.2"}','Pair each field with a label element (for/id) or add aria-label.','Screen reader users cannot tell what to type into these fields.'),
('A11Y-007','accessibility','Links with no discernible text','Anchor elements were found with no text, no aria-label, and no image alt text.','medium','{"WCAG":"2.4.4","CUSTOM":"WCAG 4.1.2"}','Add visible text or aria-label to each link so its purpose is announced.','Some links are announced as just "link" with no idea where they go.'),
('GOV-001','governance','robots.txt missing','No /robots.txt was found (404 or error).','low','{"CUSTOM":"Crawl governance"}','Publish a robots.txt that allows desired crawlers and points to the sitemap.','Search engines and AI crawlers have no instructions for this site.'),
('GOV-002','governance','XML sitemap not found','No sitemap was found at /sitemap.xml or via robots.txt.','low','{"CUSTOM":"Crawl governance"}','Generate an XML sitemap and reference it from robots.txt.','Search engines have no map of the site, so pages may be missed.'),
('GOV-003','governance','Meta description missing','No meta description was found on the homepage.','info','{"CUSTOM":"AIO readiness"}','Add a meta description of 120 to 160 characters that states what the site does.','Search and AI summaries have no short description to show for the site.'),
('GOV-004','governance','AI crawler directives','Reports which AI crawlers are blocked or unaddressed in robots.txt.','info','{"CUSTOM":"AIO readiness"}','Decide deliberately which AI crawlers to allow and record the decision in robots.txt.','This is a policy choice: allow AI assistants to read the site, or block them. Right now it is unaddressed.'),
('GOV-005','governance','Canonical link missing','No rel="canonical" link was found.','info','{"CUSTOM":"AIO readiness"}','Add a canonical link element pointing to the preferred URL of the page.','Search engines may index duplicate versions of the same page.')
on conflict (rule_id) do update set
  category = excluded.category, title = excluded.title, description = excluded.description,
  default_severity = excluded.default_severity, framework_refs = excluded.framework_refs,
  remediation = excluded.remediation, plain_english = excluded.plain_english;

------------------------------------------------------------------------------
-- Scan settings, scans, evidence, findings, sitreps
------------------------------------------------------------------------------
create table if not exists muster.website_scan_settings (
  website_id       bigint primary key references muster.websites(id) on delete cascade,
  enabled          boolean not null default true,
  cadence_minutes  integer not null default 1440 check (cadence_minutes >= 60),
  next_run_at      timestamptz not null default now(),
  last_run_at      timestamptz,
  max_pages        integer not null default 1 check (max_pages between 1 and 25),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create or replace trigger website_scan_settings_touch before update on muster.website_scan_settings
  for each row execute function muster.touch_updated_at();

create table if not exists muster.scans (
  id               bigint generated by default as identity primary key,
  organization_id  bigint not null references muster.organizations(id),
  website_id       bigint not null references muster.websites(id) on delete cascade,
  trigger          varchar(16) not null default 'manual' check (trigger in ('scheduled','manual','api','onboarding')),
  status           varchar(16) not null default 'queued' check (status in ('queued','running','complete','failed')),
  requested_by_id  bigint references muster.users(id),
  requested_by_agent_id bigint,
  target_url       varchar(1024) not null,
  final_url        varchar(1024),
  http_status      integer,
  response_ms      integer,
  engine_version   varchar(32),
  summary          jsonb not null default '{}'::jsonb,
  error_message    text,
  queued_at        timestamptz not null default now(),
  started_at       timestamptz,
  finished_at      timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index if not exists scans_website_created_idx on muster.scans (website_id, created_at desc);
create index if not exists scans_active_idx on muster.scans (status) where status in ('queued','running');
create or replace trigger scans_touch before update on muster.scans
  for each row execute function muster.touch_updated_at();

create table if not exists muster.scan_evidence (
  id               bigint generated by default as identity primary key,
  scan_id          bigint not null references muster.scans(id) on delete cascade,
  organization_id  bigint not null references muster.organizations(id),
  website_id       bigint not null references muster.websites(id) on delete cascade,
  kind             varchar(32) not null
                   check (kind in ('http_response','redirect_chain','robots_txt','sitemap','security_txt','http_probe','html_excerpt','header_set')),
  url              varchar(2048) not null,
  http_status      integer,
  content_type     varchar(160),
  response_ms      integer,
  headers          jsonb,
  excerpt          text,
  byte_length      integer,
  sha256           char(64),
  captured_at      timestamptz not null default now(),
  created_at       timestamptz not null default now()
);
create index if not exists scan_evidence_scan_idx on muster.scan_evidence (scan_id);
create index if not exists scan_evidence_website_idx on muster.scan_evidence (website_id, captured_at desc);

create table if not exists muster.findings (
  id                   bigint generated by default as identity primary key,
  organization_id      bigint not null references muster.organizations(id),
  website_id           bigint not null references muster.websites(id) on delete cascade,
  rule_id              text not null references muster.scan_rules(rule_id),
  fingerprint          char(64) not null,
  severity             varchar(16) not null check (severity in ('critical','high','medium','low','info')),
  status               varchar(16) not null default 'open'
                       check (status in ('open','reopened','resolved','accepted','false_positive')),
  title                varchar(240) not null,
  detail               text not null,
  page_url             varchar(2048) not null,
  location             varchar(400),
  confidence           varchar(8) not null default 'high' check (confidence in ('high','medium','low')),
  occurrences          integer not null default 1,
  first_seen_scan_id   bigint references muster.scans(id),
  last_seen_scan_id    bigint references muster.scans(id),
  first_seen_at        timestamptz not null default now(),
  last_seen_at         timestamptz not null default now(),
  resolved_at          timestamptz,
  resolved_by_scan_id  bigint references muster.scans(id),
  status_changed_by_id bigint references muster.users(id),
  status_note          text,
  risk_id              bigint references muster.risks(id),
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  unique (website_id, fingerprint)
);
create index if not exists findings_website_status_idx on muster.findings (website_id, status);
create index if not exists findings_org_idx on muster.findings (organization_id);
create or replace trigger findings_touch before update on muster.findings
  for each row execute function muster.touch_updated_at();

create table if not exists muster.finding_evidence (
  finding_id   bigint not null references muster.findings(id) on delete cascade,
  evidence_id  bigint not null references muster.scan_evidence(id) on delete cascade,
  scan_id      bigint not null references muster.scans(id) on delete cascade,
  created_at   timestamptz not null default now(),
  primary key (finding_id, evidence_id)
);
create index if not exists finding_evidence_scan_idx on muster.finding_evidence (scan_id);

create table if not exists muster.sitreps (
  id               bigint generated by default as identity primary key,
  organization_id  bigint not null references muster.organizations(id),
  website_id       bigint not null references muster.websites(id) on delete cascade,
  scan_id          bigint not null references muster.scans(id) on delete cascade,
  version          integer not null default 1,
  status           varchar(16) not null default 'final' check (status in ('draft','final','superseded')),
  generator        varchar(32) not null default 'deterministic-v1',
  posture_score    integer not null check (posture_score between 0 and 100),
  posture_band     varchar(8) not null check (posture_band in ('green','amber','red')),
  headline         varchar(300) not null,
  sections         jsonb not null,
  citations        jsonb not null,
  content_md       text not null,
  content_sha256   char(64) not null,
  generated_at     timestamptz not null default now(),
  created_at       timestamptz not null default now(),
  unique (scan_id, version)
);
create index if not exists sitreps_website_idx on muster.sitreps (website_id, generated_at desc);

------------------------------------------------------------------------------
-- Scoring and fingerprint helpers
------------------------------------------------------------------------------
create or replace function muster.finding_fingerprint(p_website_id bigint, p_rule_id text, p_page_url text, p_location text)
returns char(64)
language sql immutable
set search_path = ''
as $$
  select encode(sha256(convert_to(
    p_website_id::text || '|' || p_rule_id || '|' ||
    lower(regexp_replace(coalesce(p_page_url, ''), '[#?].*$', '')) || '|' ||
    coalesce(p_location, ''), 'utf8')), 'hex')::char(64);
$$;

create or replace function muster.severity_weight(p_severity text)
returns integer
language sql immutable
set search_path = ''
as $$
  select case p_severity
    when 'critical' then 25
    when 'high' then 10
    when 'medium' then 4
    when 'low' then 1
    else 0 end;
$$;

create or replace function muster.severity_rank(p_severity text)
returns integer
language sql immutable
set search_path = ''
as $$
  select case p_severity
    when 'critical' then 1 when 'high' then 2 when 'medium' then 3 when 'low' then 4 else 5 end;
$$;

create or replace function muster.posture_score(p_website_id bigint)
returns integer
language sql stable security definer
set search_path = ''
as $$
  select greatest(0, 100 - coalesce(sum(muster.severity_weight(f.severity)), 0))::integer
  from muster.findings f
  where f.website_id = p_website_id and f.status in ('open','reopened');
$$;

create or replace function muster.posture_band(p_score integer)
returns text
language sql immutable
set search_path = ''
as $$
  select case when p_score >= 85 then 'green' when p_score >= 60 then 'amber' else 'red' end;
$$;

------------------------------------------------------------------------------
-- Engine: claim, ingest, fail
------------------------------------------------------------------------------
create or replace function muster.engine_claim(p_scan_id bigint default null, p_limit integer default 3)
returns setof jsonb
language plpgsql security definer
set search_path = ''
as $$
begin
  -- Time out scans that never reported back.
  update muster.scans set status = 'failed', finished_at = now(),
    error_message = coalesce(error_message, 'Engine timeout: no result within 10 minutes')
  where status = 'running' and started_at < now() - interval '10 minutes';

  if p_scan_id is not null then
    return query
      with claimed as (
        update muster.scans s set status = 'running', started_at = now()
        where s.id = p_scan_id and s.status = 'queued'
        returning s.*
      )
      select jsonb_build_object('scan_id', c.id, 'website_id', c.website_id, 'organization_id', c.organization_id,
        'target_url', c.target_url, 'website_name', w.name, 'trigger', c.trigger,
        'max_pages', coalesce(st.max_pages, 1))
      from claimed c join muster.websites w on w.id = c.website_id
      left join muster.website_scan_settings st on st.website_id = c.website_id;
    return;
  end if;

  -- Scheduled: websites whose next_run_at is due and have nothing in flight.
  return query
    with due as (
      select st.website_id, w.organization_id, w.url, w.name, st.max_pages
      from muster.website_scan_settings st
      join muster.websites w on w.id = st.website_id
      where st.enabled and st.next_run_at <= now()
        and not exists (select 1 from muster.scans x where x.website_id = w.id and x.status in ('queued','running'))
      order by st.next_run_at
      limit p_limit
      for update of st skip locked
    ), bumped as (
      update muster.website_scan_settings st set next_run_at = now() + (st.cadence_minutes || ' minutes')::interval
      from due where st.website_id = due.website_id
      returning st.website_id
    ), created as (
      insert into muster.scans (organization_id, website_id, trigger, status, target_url, started_at)
      select d.organization_id, d.website_id, 'scheduled', 'running', d.url, now() from due d
      returning *
    )
    select jsonb_build_object('scan_id', c.id, 'website_id', c.website_id, 'organization_id', c.organization_id,
      'target_url', c.target_url, 'website_name', d.name, 'trigger', c.trigger, 'max_pages', d.max_pages)
    from created c join due d on d.website_id = c.website_id;

  -- Queued manual/api scans whose HTTP kick failed to arrive.
  return query
    with stale as (
      update muster.scans s set status = 'running', started_at = now()
      where s.id in (
        select id from muster.scans where status = 'queued' and queued_at < now() - interval '2 minutes'
        order by queued_at limit p_limit for update skip locked)
      returning s.*
    )
    select jsonb_build_object('scan_id', c.id, 'website_id', c.website_id, 'organization_id', c.organization_id,
      'target_url', c.target_url, 'website_name', w.name, 'trigger', c.trigger,
      'max_pages', coalesce(st.max_pages, 1))
    from stale c join muster.websites w on w.id = c.website_id
    left join muster.website_scan_settings st on st.website_id = c.website_id;
end;
$$;

create or replace function muster.engine_fail(p_scan_id bigint, p_error text)
returns void
language sql security definer
set search_path = ''
as $$
  update muster.scans set status = 'failed', finished_at = now(), error_message = left(p_error, 2000)
  where id = p_scan_id;
$$;

create or replace function muster.engine_ingest(p_scan_id bigint, p_scan jsonb, p_evidence jsonb, p_findings jsonb)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
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

  -- Reconcile: open http_native findings not observed in this scan are resolved by it.
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

  update muster.scans set
    status = 'complete', finished_at = now(),
    final_url = left(p_scan->>'final_url', 1024),
    http_status = nullif(p_scan->>'http_status','')::integer,
    response_ms = nullif(p_scan->>'response_ms','')::integer,
    engine_version = left(p_scan->>'engine_version', 32),
    summary = jsonb_build_object(
      'open_by_severity', v_counts, 'new', v_new, 'updated', v_updated, 'reopened', v_reopened,
      'resolved', v_resolved, 'evidence', jsonb_array_length(coalesce(p_evidence, '[]'::jsonb)),
      'posture_score', v_score, 'posture_band', muster.posture_band(v_score))
  where id = p_scan_id;

  update muster.website_scan_settings set last_run_at = now() where website_id = v_scan.website_id;

  insert into muster.activity_events (organization_id, entity_type, entity_id, action, detail, actor_id)
  values (v_scan.organization_id, 'scan', p_scan_id, 'Scan completed',
    format('%s new, %s reopened, %s resolved. Posture %s (%s).', v_new, v_reopened, v_resolved, v_score, muster.posture_band(v_score)),
    v_scan.requested_by_id);

  return jsonb_build_object('scan_id', p_scan_id, 'new', v_new, 'updated', v_updated, 'reopened', v_reopened,
    'resolved', v_resolved, 'posture_score', v_score, 'posture_band', muster.posture_band(v_score));
end;
$$;

------------------------------------------------------------------------------
-- SITREP generator (deterministic, fully cited)
------------------------------------------------------------------------------
create or replace function muster.generate_sitrep(p_scan_id bigint)
returns bigint
language plpgsql security definer
set search_path = ''
as $$
declare
  v         record;
  v_score   integer;
  v_band    text;
  v_open    integer; v_crit integer; v_high integer; v_med integer; v_low integer; v_info integer;
  v_primary bigint;
  v_top     jsonb := '[]'::jsonb;
  v_claims  jsonb := '[]'::jsonb;
  v_plain   jsonb := '[]'::jsonb;
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
  v_ev_ids  bigint[];
  v_cite    text;
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

  -- Claim helper pattern: every claim carries finding_ids and evidence_ids.
  c := c + 1;
  v_claims := v_claims || jsonb_build_object('id', 'C'||c,
    'text', format('Overall website assurance posture is %s of 100 (%s).', v_score, v_band),
    'finding_ids', to_jsonb(v_open_ids), 'evidence_ids', to_jsonb(array_remove(array[v_primary], null)));
  c := c + 1;
  v_claims := v_claims || jsonb_build_object('id', 'C'||c,
    'text', format('The homepage responded with HTTP %s in %s ms from %s.', coalesce(v.http_status::text,'no response'), coalesce(v.response_ms::text,'n/a'), coalesce(v.final_url, v.target_url)),
    'finding_ids', '[]'::jsonb, 'evidence_ids', to_jsonb(array_remove(array[v_primary], null)));
  c := c + 1;
  v_claims := v_claims || jsonb_build_object('id', 'C'||c,
    'text', format('%s open findings: %s critical, %s high, %s medium, %s low, %s informational.', v_open, v_crit, v_high, v_med, v_low, v_info),
    'finding_ids', to_jsonb(v_open_ids), 'evidence_ids', '[]'::jsonb);
  c := c + 1;
  v_claims := v_claims || jsonb_build_object('id', 'C'||c,
    'text', format('This scan added %s findings, reopened %s, and resolved %s compared with the previous state.',
      coalesce(v.summary->>'new','0'), coalesce(v.summary->>'reopened','0'), coalesce(v.summary->>'resolved','0')),
    'finding_ids', '[]'::jsonb, 'evidence_ids', '[]'::jsonb);

  for f in
    select fi.id, fi.rule_id, fi.severity, fi.title, fi.detail, fi.page_url, fi.location, fi.confidence, fi.status,
           r.category, r.remediation, r.plain_english, r.framework_refs,
           coalesce((select array_agg(fe.evidence_id order by fe.evidence_id) from muster.finding_evidence fe where fe.finding_id = fi.id), '{}') as ev_ids
    from muster.findings fi join muster.scan_rules r on r.rule_id = fi.rule_id
    where fi.website_id = v.website_id and fi.status in ('open','reopened')
    order by muster.severity_rank(fi.severity), fi.last_seen_at desc, fi.id
    limit 12
  loop
    i := i + 1;
    v_top := v_top || jsonb_build_object('rank', i, 'finding_id', f.id, 'rule_id', f.rule_id, 'category', f.category,
      'severity', f.severity, 'status', f.status, 'title', f.title, 'detail', f.detail, 'page_url', f.page_url,
      'location', f.location, 'confidence', f.confidence, 'remediation', f.remediation,
      'framework_refs', f.framework_refs, 'evidence_ids', to_jsonb(f.ev_ids));
    c := c + 1;
    v_claims := v_claims || jsonb_build_object('id', 'C'||c,
      'text', format('%s (%s): %s', f.title, f.severity, f.detail),
      'finding_ids', to_jsonb(array[f.id]), 'evidence_ids', to_jsonb(f.ev_ids));
    v_plain := v_plain || jsonb_build_object('id', 'P'||i, 'finding_id', f.id,
      'text', f.plain_english || ' Fix: ' || f.remediation,
      'evidence_ids', to_jsonb(f.ev_ids));
  end loop;

  select coalesce(jsonb_agg(jsonb_build_object('evidence_id', e.id, 'kind', e.kind, 'url', e.url,
           'http_status', e.http_status, 'sha256', e.sha256, 'captured_at', e.captured_at) order by e.id), '[]'::jsonb)
  into v_evidx
  from muster.scan_evidence e where e.scan_id = p_scan_id;

  select coalesce(jsonb_agg(jsonb_build_object('claim_id', x->>'id', 'finding_ids', x->'finding_ids', 'evidence_ids', x->'evidence_ids')), '[]'::jsonb)
  into v_cites from jsonb_array_elements(v_claims) x;

  v_headline := format('%s: posture %s/100 (%s), %s open findings, %s critical', v.website_name, v_score, v_band, v_open, v_crit);

  -- Markdown rendering with inline citations [F<finding>] [E<evidence>].
  v_md := format(E'# SITREP: %s\n\nOrganization: %s\nTarget: %s\nScan: #%s completed %s (engine %s)\nPrepared by MUSTER. Every statement below cites a finding [F] or captured evidence [E] row.\n\n## Board Report\n\n',
    v.website_name, v.org_name, v.target_url, p_scan_id, to_char(v.finished_at at time zone 'UTC', 'YYYY-MM-DD HH24:MI UTC'), coalesce(v.engine_version,'n/a'));
  for f in select x from jsonb_array_elements(v_claims) x loop
    v_cite := '';
    select string_agg(distinct '[F'||y||']', '') into v_cite from jsonb_array_elements_text(f.x->'finding_ids') y;
    v_md := v_md || '- ' || (f.x->>'text') || ' ' || coalesce(v_cite,'');
    select string_agg('[E'||y||']', '') into v_cite from jsonb_array_elements_text(f.x->'evidence_ids') y;
    v_md := v_md || coalesce(v_cite,'') || E'\n';
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
        'open', v_open, 'critical', v_crit, 'high', v_high, 'medium', v_med, 'low', v_low, 'info', v_info, 'claims', v_claims),
      'plain_english', jsonb_build_object('items', v_plain),
      'top_findings', v_top,
      'evidence_index', v_evidx),
    v_cites, v_md, encode(sha256(convert_to(v_md, 'utf8')), 'hex'))
  returning id into v_id;

  insert into muster.activity_events (organization_id, entity_type, entity_id, action, detail)
  values (v.organization_id, 'sitrep', v_id, 'SITREP generated', v_headline);

  return v_id;
end;
$$;

