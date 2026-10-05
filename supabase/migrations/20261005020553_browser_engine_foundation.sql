-- Browser engine foundation (phase 1). Adds a second scan engine, `browser`, beside `http_native`.
--
-- What this migration does NOT do: activate a single browser rule. Every rule below is inserted
-- inactive, and `browser_engine` ships dark (kill switch on, default off). Same precondition as every
-- rule before them (docs/SCAN-RULES.md): activate in a LATER migration, after a scan reports
-- engine_version 'browser-1.0.0'. Until then ingest drops their findings and counts them as
-- skipped_inactive.
--
-- Why the existing functions had to change. They assumed one engine:
--   * engine_ingest resolved every open http_native finding the scan did not re-observe. A browser
--     scan observes none of them, so it would have resolved ALL of a site's http_native findings.
--     Reconcile is now scoped to the rule family the scan's engine owns.
--   * engine_ingest wrote websites.detected_*_code unconditionally from the scan payload. A browser
--     scan carries no jurisdiction signal, so it would have nulled the detected state. Gated to
--     http_native.
--   * engine_claim and do_request_scan treated any queued scan as theirs and deduplicated across
--     engines, so a queued browser scan would have been run by the HTTP engine, or have blocked it.
--   * sync_controls scores a reference with no open findings as MET. With browser rules active, every
--     scan that never loaded a page in a browser would have scored "no axe violations" as a pass.
--     A rule now counts as assessed for a site only if its engine has completed a scan there.
--
-- Each in-place edit goes through pg_temp.sub, which refuses if the text it expects is missing or
-- appears more than once, so a changed function cannot be silently left half-edited.

create or replace function pg_temp.sub(src text, find text, repl text) returns text
language plpgsql as $f$
begin
  if position(find in src) = 0 then raise exception 'pattern not found: %', left(find, 90); end if;
  if position(find in substr(src, position(find in src) + length(find))) > 0 then
    raise exception 'pattern not unique: %', left(find, 90);
  end if;
  return replace(src, find, repl);
end $f$;

-- ---------------------------------------------------------------------------------------------
-- 1. Engine on the scan row, options, evidence kinds
-- ---------------------------------------------------------------------------------------------
alter table cavscope.scans add column if not exists engine text not null default 'http_native';
alter table cavscope.scans add column if not exists options jsonb not null default '{}'::jsonb;
alter table cavscope.scans drop constraint if exists scans_engine_check;
alter table cavscope.scans add constraint scans_engine_check check (engine in ('http_native', 'browser'));

alter table cavscope.scan_evidence drop constraint if exists scan_evidence_kind_check;
alter table cavscope.scan_evidence add constraint scan_evidence_kind_check check (kind::text = any (array[
  'http_response','redirect_chain','robots_txt','sitemap','security_txt','http_probe','html_excerpt','header_set',
  'dns_txt','dns_mx','dns_caa','dns_ds',
  -- browser engine
  'browser_page','axe_results','request_list','cookie_jar','console_log','form_inventory','csp_probe','dns_ns','active_test'
]::text[]));

-- ---------------------------------------------------------------------------------------------
-- 2. Authorization for active tests (Group C). Written only through the RPCs below.
-- ---------------------------------------------------------------------------------------------
create table if not exists cavscope.scan_authorizations (
  id bigint generated always as identity primary key,
  organization_id bigint not null references cavscope.organizations(id),
  website_id bigint not null references cavscope.websites(id) on delete cascade,
  domain text not null,
  scope text[] not null check (scope <@ array['form_endpoint_matrix','form_submit']::text[] and cardinality(scope) > 0),
  authorized_by_id bigint references cavscope.users(id),
  authorized_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '90 days',
  revoked_at timestamptz,
  note text
);
alter table cavscope.scan_authorizations enable row level security;   -- no policies: RPCs and service role only
revoke all on cavscope.scan_authorizations from anon, authenticated, public;

-- ---------------------------------------------------------------------------------------------
-- 3. Flags. enforcement is set here because this migration adds the SQL that reads them.
-- ---------------------------------------------------------------------------------------------
insert into cavscope.feature_flags (key, name, description, scope, default_enabled, kill_switch, category, surface, plan_minimum, enforcement)
values
 ('browser_engine', 'Browser engine scans',
  'When on, a workspace can request a scan that loads its pages in a headless browser (rendered accessibility, requests, cookies, forms). The scan runs on a separate worker; with no worker running, a requested scan stays queued.',
  'platform', false, true, 'workspace', 'public.cavscope_request_browser_scan', null, array['sql']),
 ('browser_active_tests', 'Browser engine active tests',
  'When on, a scan may run the tests that SEND data to the site (form endpoint matrix, live form submit), but only against a site with a current, unrevoked authorization record from an executive of the owning organization and a verified site.',
  'platform', false, true, 'workspace', 'public.cavscope_request_browser_scan', null, array['sql'])
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------------------------
-- 4. Scoping the existing engine functions to their own engine
-- ---------------------------------------------------------------------------------------------
do $$
declare d text;
begin
  d := pg_get_functiondef('cavscope.engine_claim(bigint,integer)'::regprocedure);
  d := pg_temp.sub(d, $q$where s.id = p_scan_id and s.status = 'queued'$q$,
                      $q$where s.id = p_scan_id and s.status = 'queued' and s.engine = 'http_native'$q$);
  d := pg_temp.sub(d, $q$where x.website_id = w.id and x.status in ('queued','running'))$q$,
                      $q$where x.website_id = w.id and x.engine = 'http_native' and x.status in ('queued','running'))$q$);
  d := pg_temp.sub(d, $q$select id from cavscope.scans where status = 'queued' and queued_at < now() - interval '2 minutes'$q$,
                      $q$select id from cavscope.scans where status = 'queued' and engine = 'http_native' and queued_at < now() - interval '2 minutes'$q$);
  execute d;

  d := pg_get_functiondef('cavscope.do_request_scan(bigint,bigint,bigint,text)'::regprocedure);
  d := pg_temp.sub(d, $q$where website_id = p_website_id and status in ('queued','running') order by created_at desc limit 1$q$,
                      $q$where website_id = p_website_id and engine = 'http_native' and status in ('queued','running') order by created_at desc limit 1$q$);
  execute d;

  d := pg_get_functiondef('cavscope.engine_ingest(bigint,jsonb,jsonb,jsonb)'::regprocedure);
  d := pg_temp.sub(d, $q$and exists (select 1 from cavscope.scan_rules r where r.rule_id = f.rule_id and r.check_type = 'http_native');$q$,
                      $q$and exists (select 1 from cavscope.scan_rules r where r.rule_id = f.rule_id
                   and r.check_type = case v_scan.engine when 'browser' then 'browser' else 'http_native' end);$q$);
  d := pg_temp.sub(d, $q$where id = v_scan.website_id;$q$,
                      $q$where id = v_scan.website_id and v_scan.engine = 'http_native';$q$);
  d := pg_temp.sub(d, $q$'posture_band', cavscope.posture_band(v_score))
  where id = p_scan_id;$q$,
                      $q$'posture_band', cavscope.posture_band(v_score),
      'engine', v_scan.engine,
      'browser_checks', coalesce(p_scan->'browser_checks', '[]'::jsonb),
      'pages_visited', p_scan->'pages_visited')
  where id = p_scan_id;$q$);
  execute d;
end $$;

-- A rule counts as assessed for a site only if its engine has completed a scan there. A reference whose
-- rules are all unassessed reads not_assessed, never met.
create or replace function cavscope.sync_controls(p_website_id bigint)
returns integer
language plpgsql security definer set search_path to ''
as $function$
declare
  v_scans integer;
  v_written integer := 0;
begin
  select count(*) into v_scans
  from cavscope.scans where website_id = p_website_id and status = 'complete';

  with has_browser as (
    select exists (select 1 from cavscope.scans
                    where website_id = p_website_id and status = 'complete' and engine = 'browser') as b
  ),
  refs as (
    select c.framework, c.reference,
           array_agg(distinct c.rule_id order by c.rule_id) as rules,
           array_agg(distinct c.rule_id order by c.rule_id)
             filter (where r.check_type <> 'browser' or hb.b) as assessed_rules
    from cavscope.rule_control_refs() c
    join cavscope.scan_rules r on r.rule_id = c.rule_id
    cross join has_browser hb
    group by c.framework, c.reference
  ),
  scored as (
    select
      r.framework, r.reference, r.rules, r.assessed_rules,
      -- Informational rules are inventory, not defects (see TP-001): they never drag a control to partial.
      count(*) filter (
        where f.status in ('open','reopened') and f.severity in ('critical','high')
      ) as open_bad,
      count(*) filter (
        where f.status in ('open','reopened') and f.severity in ('medium','low')
      ) as open_soft
    from refs r
    left join cavscope.findings f
      on f.website_id = p_website_id
     and f.rule_id::text = any(r.rules)
    group by r.framework, r.reference, r.rules, r.assessed_rules
  )
  insert into cavscope.controls
    (website_id, framework, reference, title, description, assessment, source)
  select
    p_website_id,
    s.framework,
    s.reference,
    cavscope.framework_label(s.framework) || ' ' || s.reference,
    format(
      '%s CavScope check%s map to this reference: %s. Assessment reflects only what CavScope assesses from the public web surface and is not a full control assessment.',
      array_length(s.rules, 1),
      case when array_length(s.rules, 1) = 1 then '' else 's' end,
      array_to_string(s.rules, ', ')),
    case
      when v_scans = 0 then 'not_assessed'
      when s.assessed_rules is null then 'not_assessed'
      when s.open_bad > 0 then 'not_met'
      when s.open_soft > 0 then 'partial'
      else 'met'
    end,
    'derived'
  from scored s
  on conflict (website_id, framework, reference) do update
    set title = case when cavscope.controls.source = 'derived' then excluded.title else cavscope.controls.title end,
        description = case when cavscope.controls.source = 'derived' then excluded.description else cavscope.controls.description end,
        assessment = case when cavscope.controls.source = 'derived' then excluded.assessment else cavscope.controls.assessment end,
        updated_at = case when cavscope.controls.source = 'derived' then now() else cavscope.controls.updated_at end;

  get diagnostics v_written = row_count;
  return v_written;
end;
$function$;

-- ---------------------------------------------------------------------------------------------
-- 5. Requesting, claiming and authorizing browser scans
-- ---------------------------------------------------------------------------------------------
create or replace function cavscope.site_host(p_url text) returns text
language sql immutable set search_path to ''
as $$ select lower(regexp_replace(p_url, '^[a-z]+://([^/:?#]+).*$', '\1', 'i')) $$;

-- The one place that decides whether active tests are authorized. A request for them without a
-- valid record is not an error: the scan runs without them and the report says so.
create or replace function cavscope.active_test_authorization(p_website_id bigint)
returns bigint
language sql stable security definer set search_path to ''
as $$
  select a.id
    from cavscope.scan_authorizations a
    join cavscope.websites w on w.id = a.website_id
   where a.website_id = p_website_id
     and a.revoked_at is null and a.expires_at > now()
     and w.verified_at is not null
     and a.domain = cavscope.site_host(w.url)
   order by a.authorized_at desc
   limit 1
$$;

create or replace function cavscope.do_request_browser_scan(p_website_id bigint, p_user_id bigint, p_trigger text, p_cache_bust boolean, p_active_tests boolean)
returns jsonb
language plpgsql security definer set search_path to ''
as $$
declare
  v_org bigint; v_url text; v_existing bigint; v_scan_id bigint; v_auth bigint := null; v_opts jsonb;
begin
  select organization_id, url into v_org, v_url from cavscope.websites where id = p_website_id;
  if v_org is null then raise exception 'website % not found', p_website_id using errcode = 'P0002'; end if;

  select id into v_existing from cavscope.scans
   where website_id = p_website_id and engine = 'browser' and status in ('queued','running')
   order by created_at desc limit 1;
  if v_existing is not null then
    return jsonb_build_object('scan_id', v_existing, 'status', 'in_flight', 'deduplicated', true);
  end if;

  if p_active_tests and cavscope.flag_state_for_org(v_org, 'browser_active_tests') then
    v_auth := cavscope.active_test_authorization(p_website_id);
  end if;
  v_opts := jsonb_build_object(
    'cache_bust', coalesce(p_cache_bust, false),
    'active_tests_requested', coalesce(p_active_tests, false),
    'active_tests', v_auth is not null,
    'authorization_id', v_auth);

  insert into cavscope.scans (organization_id, website_id, trigger, status, requested_by_id, target_url, engine, options)
  values (v_org, p_website_id, p_trigger, 'queued', p_user_id, v_url, 'browser', v_opts)
  returning id into v_scan_id;

  insert into cavscope.activity_events (organization_id, entity_type, entity_id, action, detail, actor_id)
  values (v_org, 'scan', v_scan_id, 'Browser scan requested',
          format('Trigger: %s. Active tests: %s.', p_trigger,
                 case when v_auth is not null then 'authorized'
                      when p_active_tests then 'requested, not authorized (skipped)' else 'not requested' end),
          p_user_id);

  return jsonb_build_object('scan_id', v_scan_id, 'status', 'queued', 'deduplicated', false, 'options', v_opts);
end;
$$;

create or replace function public.cavscope_request_browser_scan(p_website_id bigint, p_cache_bust boolean default false, p_active_tests boolean default false)
returns jsonb
language plpgsql security definer set search_path to ''
as $$
declare v_org bigint := cavscope.website_org(p_website_id);
begin
  if not cavscope.can_write_org(v_org) then raise exception 'forbidden' using errcode = '42501'; end if;
  if not cavscope.has_flag(v_org, 'browser_engine') then raise exception 'browser scans are not enabled for this organization' using errcode = '42501'; end if;
  if not cavscope.has_flag(v_org, 'manual_scans') then raise exception 'manual scans are disabled for this organization' using errcode = '42501'; end if;
  return cavscope.do_request_browser_scan(p_website_id, cavscope.current_user_id(), 'manual', p_cache_bust, p_active_tests);
end;
$$;

-- Executive of the owning organization only (not super admin: org_role returns 'super_admin' for them),
-- on a verified site. Active tests send data to the site, so the person who may say yes is its owner.
create or replace function public.cavscope_grant_scan_authorization(p_website_id bigint, p_scope text[], p_note text default null, p_days integer default 90)
returns jsonb
language plpgsql security definer set search_path to ''
as $$
declare v_org bigint := cavscope.website_org(p_website_id); v_url text; v_verified timestamptz; v_id bigint;
begin
  if cavscope.org_role(v_org) is distinct from 'executive' then
    raise exception 'only an executive of the owning organization can authorize active tests' using errcode = '42501';
  end if;
  select url, verified_at into v_url, v_verified from cavscope.websites where id = p_website_id;
  if v_verified is null then
    raise exception 'verify ownership of this site before authorizing active tests' using errcode = '42501';
  end if;
  if p_days < 1 or p_days > 365 then raise exception 'authorization length must be 1 to 365 days' using errcode = '22023'; end if;
  insert into cavscope.scan_authorizations (organization_id, website_id, domain, scope, authorized_by_id, expires_at, note)
  values (v_org, p_website_id, cavscope.site_host(v_url), p_scope, cavscope.current_user_id(), now() + make_interval(days => p_days), left(p_note, 500))
  returning id into v_id;
  insert into cavscope.activity_events (organization_id, entity_type, entity_id, action, detail, actor_id)
  values (v_org, 'website', p_website_id, 'Active-test authorization granted',
          format('Scope: %s. Domain: %s. Expires in %s days.', array_to_string(p_scope, ', '), cavscope.site_host(v_url), p_days),
          cavscope.current_user_id());
  return jsonb_build_object('authorization_id', v_id, 'domain', cavscope.site_host(v_url), 'scope', p_scope);
end;
$$;

create or replace function public.cavscope_revoke_scan_authorization(p_authorization_id bigint)
returns void
language plpgsql security definer set search_path to ''
as $$
declare v_org bigint; v_site bigint;
begin
  select organization_id, website_id into v_org, v_site from cavscope.scan_authorizations where id = p_authorization_id;
  if v_org is null then raise exception 'authorization not found' using errcode = 'P0002'; end if;
  if cavscope.org_role(v_org) is distinct from 'executive' then raise exception 'forbidden' using errcode = '42501'; end if;
  update cavscope.scan_authorizations set revoked_at = now() where id = p_authorization_id and revoked_at is null;
  insert into cavscope.activity_events (organization_id, entity_type, entity_id, action, detail, actor_id)
  values (v_org, 'website', v_site, 'Active-test authorization revoked', 'Authorization #' || p_authorization_id, cavscope.current_user_id());
end;
$$;

-- Worker claim. Browser scans are never kicked over HTTP: the worker polls this.
create or replace function cavscope.engine_claim_browser(p_scan_id bigint default null, p_limit integer default 1)
returns setof jsonb
language plpgsql security definer set search_path to ''
as $$
begin
  update cavscope.scans set status = 'failed', finished_at = now(),
    error_message = coalesce(error_message, 'Engine timeout: no result within 20 minutes')
   where engine = 'browser' and status = 'running' and started_at < now() - interval '20 minutes';

  return query
    with picked as (
      select s.id from cavscope.scans s
       where s.engine = 'browser' and s.status = 'queued' and (p_scan_id is null or s.id = p_scan_id)
       order by s.queued_at limit p_limit for update skip locked
    ), claimed as (
      update cavscope.scans s set status = 'running', started_at = now()
        from picked where s.id = picked.id returning s.*
    )
    select jsonb_build_object('scan_id', c.id, 'website_id', c.website_id, 'organization_id', c.organization_id,
      'target_url', c.target_url, 'website_name', w.name, 'trigger', c.trigger, 'options', c.options,
      'verified', w.verified_at is not null)
    from claimed c join cavscope.websites w on w.id = c.website_id;
end;
$$;

create or replace function public.cavscope_engine_claim_browser(p_scan_id bigint default null, p_limit integer default 1)
returns setof jsonb
language sql security definer set search_path to ''
as $$ select * from cavscope.engine_claim_browser(p_scan_id, p_limit) $$;

-- Engine RPCs are called only by a worker holding the service role. Supabase's default privileges grant
-- EXECUTE on new public functions to anon and authenticated; revoke by name (CLAUDE.md).
revoke all on function public.cavscope_engine_claim_browser(bigint, integer) from public, anon, authenticated;
grant execute on function public.cavscope_engine_claim_browser(bigint, integer) to service_role;
revoke all on function cavscope.engine_claim_browser(bigint, integer) from public, anon, authenticated;
revoke all on function cavscope.do_request_browser_scan(bigint, bigint, text, boolean, boolean) from public, anon, authenticated;
revoke all on function cavscope.active_test_authorization(bigint) from public, anon, authenticated;
revoke all on function public.cavscope_request_browser_scan(bigint, boolean, boolean) from public, anon;
grant execute on function public.cavscope_request_browser_scan(bigint, boolean, boolean) to authenticated;
revoke all on function public.cavscope_grant_scan_authorization(bigint, text[], text, integer) from public, anon;
grant execute on function public.cavscope_grant_scan_authorization(bigint, text[], text, integer) to authenticated;
revoke all on function public.cavscope_revoke_scan_authorization(bigint) from public, anon;
grant execute on function public.cavscope_revoke_scan_authorization(bigint) to authenticated;

-- ---------------------------------------------------------------------------------------------
-- 6. The report: title shows the scanned host (REPORT-001), scope text depends on which engines ran,
--    and browser results are listed, passes included.
-- ---------------------------------------------------------------------------------------------
-- Scan 245 was titled "After Today" with target https://anthonywashingtonsr.com/. Not a generator
-- fault: websites.name for that site IS "After Today". But a title that can disagree with its own Target
-- row misleads, so the host is always in the title unless the name already says it.
create or replace function cavscope.sitrep_title(p_name text, p_target text) returns text
language sql immutable set search_path to ''
as $$
  select case
    when p_target is null or cavscope.site_host(p_target) = '' then coalesce(p_name, '')
    when p_name is null or p_name = '' then cavscope.site_host(p_target)
    when lower(p_name) like '%' || regexp_replace(cavscope.site_host(p_target), '^www\.', '') || '%' then p_name
    else p_name || ' (' || cavscope.site_host(p_target) || ')'
  end
$$;

-- The browser scan whose results belong in this report: its own if it is one, else the site's latest
-- complete browser scan within 7 days before this scan finished.
create or replace function cavscope.sitrep_browser_scan(p_scan_id bigint) returns bigint
language sql stable security definer set search_path to ''
as $$
  select case when s.engine = 'browser' then s.id else
    (select b.id from cavscope.scans b
      where b.website_id = s.website_id and b.engine = 'browser' and b.status = 'complete'
        and b.finished_at <= coalesce(s.finished_at, now()) and b.finished_at > coalesce(s.finished_at, now()) - interval '7 days'
      order by b.finished_at desc limit 1) end
  from cavscope.scans s where s.id = p_scan_id
$$;

create or replace function cavscope.sitrep_browser_md(p_scan_id bigint) returns text
language plpgsql stable security definer set search_path to ''
as $$
declare b cavscope.scans%rowtype; v_id bigint := cavscope.sitrep_browser_scan(p_scan_id); v_md text; c jsonb; v_cites text;
begin
  if v_id is null then return ''; end if;
  select * into b from cavscope.scans where id = v_id;
  v_md := format(E'\n## Browser Engine Results\n\nEngine %s, scan #%s, completed %s. Pages visited: %s. Every check is listed, including those that passed. A passed check means these checks found nothing on this date; it is not a statement that the site is secure or accessible.\n\n| Check | Outcome | Detail |\n|---|---|---|\n',
    coalesce(b.engine_version, 'browser'), b.id, to_char(b.finished_at at time zone 'UTC', 'YYYY-MM-DD HH24:MI UTC'),
    coalesce(b.summary->>'pages_visited', 'n/a'));
  for c in select x from jsonb_array_elements(coalesce(b.summary->'browser_checks', '[]'::jsonb)) x loop
    v_md := v_md || format('| %s | %s | %s |', c->>'rule_id', replace(coalesce(c->>'outcome', ''), '_', ' '),
      replace(replace(coalesce(c->>'detail', ''), '|', '/'), E'\n', ' ')) || E'\n';
  end loop;
  if (b.options->>'active_tests_requested')::boolean and not coalesce((b.options->>'active_tests')::boolean, false) then
    v_md := v_md || E'\nActive tests were requested for this scan but the site has no current authorization on file, so none were run.\n';
  end if;
  return v_md;
end;
$$;

do $$
declare d text;
begin
  d := pg_get_functiondef('cavscope.generate_sitrep(bigint)'::regprocedure);
  d := pg_temp.sub(d, $q$v.website_name, v.org_name, v.target_url, p_scan_id,$q$,
                      $q$cavscope.sitrep_title(v.website_name, v.target_url), v.org_name, v.target_url, p_scan_id,$q$);
  d := pg_temp.sub(d,
    $q$  v_scope := v_scope || to_jsonb('CavScope reads this site over HTTP and DNS only. It does not execute JavaScript, so anything a page builds in the browser after load is not assessed.'::text);$q$,
    $q$  if cavscope.sitrep_browser_scan(p_scan_id) is not null then
    v_scope := v_scope || to_jsonb('CavScope reads this site over HTTP and DNS, and a browser engine (headless Chromium) loaded a bounded set of its pages and ran their JavaScript, so content a page builds after load was assessed on those pages only. Pages the browser engine did not visit are not assessed.'::text);
    v_scope := v_scope || to_jsonb('The browser engine did not test with a screen reader, keyboard navigation (focus order, traps, focus visibility), zoom or reflow at 200 to 400 percent, Core Web Vitals, broken links across the whole site, or SPF and DKIM discovery. Automated accessibility rules find only part of what a person would, and this is not an accessibility audit of record.'::text);
  else
    v_scope := v_scope || to_jsonb('CavScope reads this site over HTTP and DNS only. It does not execute JavaScript, so anything a page builds in the browser after load is not assessed.'::text);
  end if;$q$);
  d := pg_temp.sub(d, $q$v_md := v_md || format(E'\n## Controls$q$,
                      $q$v_md := v_md || cavscope.sitrep_browser_md(p_scan_id);
  v_md := v_md || format(E'\n## Controls$q$);
  execute d;
end $$;

revoke all on function cavscope.sitrep_title(text, text) from public, anon, authenticated;
revoke all on function cavscope.sitrep_browser_scan(bigint) from public, anon, authenticated;
revoke all on function cavscope.sitrep_browser_md(bigint) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------
-- 7. The rules. All inactive. See the header.
-- ---------------------------------------------------------------------------------------------
insert into cavscope.scan_rules (rule_id, category, title, description, default_severity, check_type, framework_refs, remediation, plain_english, active)
values
('A11Y-008', 'accessibility', 'Accessibility violations found in the rendered page',
 'axe-core, run in a headless browser against each page after its JavaScript executed, reported a violation. One finding per axe rule per site; the detail lists the affected pages and node counts. Severity follows axe impact: critical high, serious medium, moderate low, minor info.',
 'medium', 'browser', '{"WCAG": "1.1.1, 1.3.1, 1.4.3, 2.4.4, 4.1.2"}',
 'Open the listed pages, find the elements named in the finding, and fix them as the axe rule describes. Re-run the browser scan to confirm the rule no longer fires.',
 'An automated accessibility checker loaded your pages the way a visitor''s browser does and found things that can stop some people, such as screen reader users, from using them. Automated checks find only part of the problems a person would.', false),
('A11Y-009', 'accessibility', 'Accessibility checks that need a person to review',
 'axe-core could not decide these automatically (its incomplete results). Contrast checks over gradients or images are resolved from the page''s own colours where possible and reported as passed or failed; the rest are listed for review. Never counted as a pass or a fail.',
 'info', 'browser', '{"WCAG": "1.4.3, 1.4.11"}',
 'Review each listed element by eye or with a contrast tool. Where the text sits on an image or gradient, check the weakest part of the background.',
 'The checker could not tell, on its own, whether these pass. They are listed so a person can look; they are not counted as problems or as passes.', false),
('A11Y-010', 'accessibility', 'Page structure basics missing in the rendered page',
 'On a page after rendering: the title is missing or empty, there is not exactly one h1, the html lang attribute is missing or invalid, or images have no alt attribute.',
 'medium', 'browser', '{"WCAG": "1.1.1, 2.4.2, 3.1.1, 2.4.6"}',
 'Give every page a unique title, one h1, a valid lang on the html element, and an alt attribute on every image (empty alt for decorative ones).',
 'Each page should say what it is called, what its main heading is, what language it is in, and describe its images. Pages that are missing these are harder to use with assistive technology and in search results.', false),
('TP-002', 'third_party', 'Third-party requests observed in the browser',
 'Every network request the browser made while loading the pages, grouped by host outside the site''s own registered domain. Supersedes TP-001 when the browser engine ran. Zero third-party hosts is reported as a result.',
 'info', 'browser', '{"SOC_2": "CC9.2", "NIST_800_53": "SR-3, SA-9", "NIST_CSF_V2": "GV.SC-04", "OWASP_TOP10": "A03:2025"}',
 'Review each host, remove the ones that are not needed, and add Subresource Integrity to scripts where supported.',
 'These are the outside companies your pages talk to when a visitor loads them, including ones that scripts add after the page loads. Keep the list short and known.', false),
('PRIV-006', 'privacy', 'Cookies or trackers observed before any interaction',
 'After the first load and before any click, scroll or consent action, the cookie jar held advertising or analytics cookies, or the page requested a known tracker host. Worded as observed before interaction, not as a legal conclusion. Zero cookies is reported as a result.',
 'medium', 'browser', '{}',
 'If these are not meant to load before a visitor agrees, load them only after consent. Check what your privacy policy says about them.',
 'Before anyone clicked anything, these cookies or tracking services were already loading. Whether that is a problem depends on your policy and on the laws that apply to your visitors, which this report does not decide.', false),
('SEC-021', 'security', 'Browser reported blocked or failed loads on the site',
 'The browser console reported a Content Security Policy refusal, or a first-party asset request failed. A CSP that blocks the site''s own content means a page is partly broken for visitors.',
 'medium', 'browser', '{"NIST_CSF_V2": "PR.PS-01", "OWASP_TOP10": "A02:2025"}',
 'Read the console messages in the evidence, then either allow the legitimate source in the policy or remove the blocked reference.',
 'Your security policy or a broken link stopped something on your own pages from loading. Visitors may see missing images, fonts or features.', false),
('SEC-022', 'security', 'Content Security Policy enforcement observed in the browser',
 'Informational. A harmless inline script was injected on one page. If the browser refused it, the CSP is enforced against inline script; if it ran, it is not.',
 'info', 'browser', '{"SOC_2": "CC6.6", "NIST_800_53": "CM-6", "NIST_CSF_V2": "PR.PS-01", "OWASP_TOP10": "A02:2025"}',
 'If inline script ran, add a Content-Security-Policy that does not allow unsafe-inline for scripts.',
 'We tried to run a harmless line of script that was not on your page''s approved list. This tells you whether your browser-side policy actually stops injected scripts.', false),
('FORM-001', 'security', 'Form inventory and submission target',
 'Each form''s resolved action, method and fields. A form whose action is empty, #, or javascript: does not submit anywhere; a form whose action is not HTTPS sends visitors'' input unprotected.',
 'high', 'browser', '{"OWASP_TOP10": "A02:2025"}',
 'Point the form at a real HTTPS endpoint, or remove it.',
 'These forms either go nowhere when someone presses Submit, or send what people type over a connection that is not encrypted.', false),
('FORM-002', 'privacy', 'Text-message consent readiness',
 'For a form with a phone field or SMS consent box: consent unchecked by default, STOP / HELP / message-and-data-rates / message-frequency wording present, working privacy and SMS terms links, no consent-as-condition-of-purchase statement, phone not required unless consent is. Evidence for carrier registration readiness, not legal advice.',
 'medium', 'browser', '{}',
 'Add whichever wording or link the checklist shows as missing. Confirm the final wording with the registration provider or your own advisor.',
 'If your form signs people up for text messages, mobile carriers look for specific wording and links. This lists which ones are present and which are missing.', false),
('FORM-003', 'privacy', 'Parent or guardian notice near a form on a youth-facing site',
 'The page mentions athletes, students, youth, kids or parents and a form collects personal data, with no parent/guardian or under-18 notice near the form. Informational: consider adding. Not a legal conclusion.',
 'info', 'browser', '{}',
 'Consider a short notice near the form saying who it is for and that a parent or guardian should complete it for anyone under 18.',
 'This site appears to serve young people and has a form that collects personal details. A short note near the form about parents or guardians is worth considering.', false),
('FORM-010', 'security', 'Form endpoint behaviour under test (authorized)',
 'Active test, only with a current authorization on a verified site. Seven requests against the form endpoint: valid, invalid option, SMS consent without phone, honeypot filled, too fast, disallowed origin, CORS preflight. Reports deviations such as wildcard CORS or a stored bot submission.',
 'medium', 'browser', '{"OWASP_TOP10": "A02:2025"}',
 'Fix each deviation listed: validate input, reject disallowed origins, and do not store submissions that fail the honeypot or timing checks.',
 'With your permission, we sent test submissions to your form''s back end to see how it handles bad, bot-like and cross-site requests.', false),
('FORM-011', 'availability', 'Live form submission test (authorized)',
 'Active test, only with a current authorization on a verified site. The real form was filled with obvious test data and submitted in the browser. Passes if the page shows a success state and the endpoint answers 2xx. Delivery to the owner is not verified unless the client supplies a read-only verification hook.',
 'high', 'browser', '{}',
 'If the form failed, check the endpoint and the page''s success handling. Delete the test submission using the marker strings in the evidence.',
 'With your permission, we filled in and submitted your real contact form with test details to confirm it works from start to finish.', false)
on conflict (rule_id) do nothing;
