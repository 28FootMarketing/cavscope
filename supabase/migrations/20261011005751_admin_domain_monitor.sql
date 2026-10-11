-- Domain Monitor section of the Super Admin Console (admin.html).
--
-- The section was a "not instrumented" stub: no table held domain state between runs. Half of that is
-- true and stays stated on the page (the engine records no registrar data and no certificate), but the
-- other half was not: every completed scan already writes DNS evidence unconditionally, including an
-- explicit "(none)" row when a record is absent (dns_mx, dns_txt for SPF, DMARC and MTA-STS, dns_caa,
-- dns_ds) plus the response headers (header_set). Kept per scan, that is a time series. This function
-- returns, for each registered site, what its latest completed scan saw, and what changed between scans
-- over the last 30 days.
--
-- Three rules this follows, the same ones as the AI Readiness view:
--   * Absent is only claimed when the scan wrote the row that says so. A record with no evidence row in
--     the latest scan is 'not_observed', never 'missing' (older scans pre-date some record types).
--   * HSTS is 'absent' only if the engine actually received a response. A scan whose page could not be
--     read (http_status null) says 'not_observed', not "no HSTS".
--   * MTA-STS is present only if a TXT record starting v=STSv1 is there: the _mta-sts name can return an
--     unrelated TXT (hanoverymca.org returns its SPF record there).
-- Changes compare sorted lines, so a resolver returning the same records in a different order is not drift.
-- Evidence text is third-party DNS content: the page must escape it. Super admin only; anon has no execute.

create or replace function public.cavscope_admin_domain_monitor()
 returns jsonb
 language plpgsql
 stable
 security definer
 set search_path to ''
as $function$
begin
  if not cavscope.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;

  return jsonb_build_object(
    'generated_at', now(),
    'window_days', 30,
    'sites', coalesce((
      with latest as (
        select distinct on (s.website_id) s.website_id, s.id as scan_id, s.finished_at, s.engine_version
          from cavscope.scans s where s.status = 'complete' order by s.website_id, s.id desc
      ),
      ev as (
        select l.website_id, e.kind, e.url, e.excerpt, e.headers, e.http_status
          from latest l join cavscope.scan_evidence e on e.scan_id = l.scan_id
         where e.kind in ('dns_mx', 'dns_txt', 'dns_caa', 'dns_ds', 'header_set')
      ),
      cur as (
        select w.id as website_id,
          (select e.excerpt from ev e where e.website_id = w.id and e.kind = 'dns_mx' limit 1) as mx,
          (select substring(e.url from '^dns:([^?]+)\?type=MX') from ev e where e.website_id = w.id and e.kind = 'dns_mx' limit 1) as domain,
          (select e.excerpt from ev e where e.website_id = w.id and e.kind = 'dns_txt'
              and e.url !~ '^dns:_' and e.url !~ '&walk=' limit 1) as txt,
          (select e.excerpt from ev e where e.website_id = w.id and e.kind = 'dns_txt' and e.url ~ '&walk=spf' limit 1) as spf_walk,
          (select e.excerpt from ev e where e.website_id = w.id and e.kind = 'dns_txt' and e.url ~ '^dns:_dmarc\.' limit 1) as dmarc,
          (select e.excerpt from ev e where e.website_id = w.id and e.kind = 'dns_txt' and e.url ~ '^dns:_mta-sts\.' limit 1) as mta_sts,
          (select e.excerpt from ev e where e.website_id = w.id and e.kind = 'dns_caa' limit 1) as caa,
          (select e.excerpt from ev e where e.website_id = w.id and e.kind = 'dns_ds' limit 1) as ds,
          (select count(*) from ev e where e.website_id = w.id and e.kind = 'header_set' and e.http_status is not null) as header_rows,
          (select max(e.headers ->> 'strict-transport-security') from ev e
            where e.website_id = w.id and e.kind = 'header_set' and e.http_status is not null) as hsts
        from cavscope.websites w
      ),
      norm as (
        select s.website_id, s.id as scan_id, s.finished_at,
               case when e.kind = 'dns_mx' then 'MX'
                    when e.kind = 'dns_caa' then 'CAA'
                    when e.kind = 'dns_ds' then 'DNSSEC'
                    when e.url ~ '^dns:_dmarc\.' then 'DMARC'
                    when e.url !~ '^dns:_' and e.url !~ '&walk=' then 'SPF' end as field,
               (select string_agg(l, E'\n' order by l)
                  from regexp_split_to_table(e.excerpt, E'\n') l
                 where e.kind <> 'dns_txt' or e.url ~ '^dns:_dmarc\.' or l ~* '^v=spf1') as value
          from cavscope.scans s join cavscope.scan_evidence e on e.scan_id = s.id
         where s.status = 'complete' and s.finished_at > now() - interval '30 days'
           and e.kind in ('dns_mx', 'dns_caa', 'dns_ds', 'dns_txt')
      ),
      per_scan as (
        select website_id, scan_id, finished_at, field, coalesce(string_agg(distinct value, E'\n'), '(none)') as value
          from norm where field is not null group by website_id, scan_id, finished_at, field
      ),
      chg as (
        select t.website_id, t.field, t.finished_at, t.prev_value, t.value
          from (select p.*, lag(p.value) over (partition by p.website_id, p.field order by p.scan_id) as prev_value
                  from per_scan p) t
         where t.prev_value is not null and t.prev_value is distinct from t.value
      ),
      chg_site as (
        select c.website_id, count(*) as n,
               (select coalesce(jsonb_agg(jsonb_build_object('record', r.field, 'at', r.finished_at,
                         'from', left(r.prev_value, 160), 'to', left(r.value, 160)) order by r.finished_at desc), '[]'::jsonb)
                  from (select * from chg c2 where c2.website_id = c.website_id order by c2.finished_at desc limit 6) r) as recent
          from chg c group by c.website_id
      )
      select jsonb_agg(jsonb_build_object(
        'website_id', w.id,
        'website', w.name,
        'url', w.url,
        'organization_id', o.id,
        'organization', o.name,
        'sandbox', o.is_admin_sandbox,
        'scanned', (l.scan_id is not null),
        'scan_id', l.scan_id,
        'scanned_at', l.finished_at,
        'engine_version', l.engine_version,
        'scan_enabled', coalesce(ss.enabled, false),
        'cadence_minutes', ss.cadence_minutes,
        'domain', c.domain,
        'mx', case when c.mx is null then jsonb_build_object('state', 'not_observed')
                   when c.mx ~* '^\(no MX records\)' then jsonb_build_object('state', 'none')
                   else jsonb_build_object('state', 'present', 'records', to_jsonb((select array_agg(x) from (select regexp_split_to_table(c.mx, E'\n') x limit 6) q))) end,
        'spf', case when c.txt is null then jsonb_build_object('state', 'not_observed')
                    else (select case when n = 0 then jsonb_build_object('state', 'missing')
                                      when n > 1 then jsonb_build_object('state', 'multiple')
                                      else jsonb_build_object('state', 'present', 'value', left(v, 200),
                                             'lookups', nullif(substring(c.spf_walk from '^(\d+) of \d+ DNS lookups'), '')::int) end
                            from (select count(*) filter (where l ~* '^v=spf1') as n,
                                         max(l) filter (where l ~* '^v=spf1') as v
                                    from regexp_split_to_table(c.txt, E'\n') l) z) end,
        'dmarc', case when c.dmarc is null then jsonb_build_object('state', 'not_observed')
                      when c.dmarc ~* '^no DMARC' then jsonb_build_object('state', 'missing')
                      else (select case when n > 1 then jsonb_build_object('state', 'multiple')
                                        when n = 0 then jsonb_build_object('state', 'missing')
                                        else jsonb_build_object('state', coalesce(lower(substring(v from '(?i)(?:^|[ ;])p=([a-z]+)')), 'unknown'),
                                               'value', left(v, 200)) end
                              from (select count(*) filter (where l ~* '^v=DMARC1') as n,
                                           max(l) filter (where l ~* '^v=DMARC1') as v
                                      from regexp_split_to_table(c.dmarc, E'\n') l) z) end,
        'caa', case when c.caa is null then jsonb_build_object('state', 'not_observed')
                    when not exists (select 1 from regexp_split_to_table(c.caa, E'\n') l where l !~ ': \(none\)\s*$') then jsonb_build_object('state', 'none')
                    else jsonb_build_object('state', 'present') end,
        'dnssec', case when c.ds is null then jsonb_build_object('state', 'not_observed')
                       when c.ds ~* '^\(no DS records\)' then jsonb_build_object('state', 'off')
                       else jsonb_build_object('state', 'on') end,
        'mta_sts', case when c.mta_sts is null then jsonb_build_object('state', 'not_observed')
                        when c.mta_sts ~* 'v=STSv1' then jsonb_build_object('state', 'present')
                        else jsonb_build_object('state', 'none') end,
        'hsts', case when l.scan_id is null or c.header_rows = 0 then jsonb_build_object('state', 'not_observed')
                     when c.hsts is null then jsonb_build_object('state', 'absent')
                     else jsonb_build_object('state', 'present', 'value', left(c.hsts, 120),
                            'max_age', nullif(substring(c.hsts from '(?i)max-age=(\d+)'), '')::bigint) end,
        'changes_30d', coalesce(cs.n, 0),
        'recent_changes', coalesce(cs.recent, '[]'::jsonb)
      ) order by o.is_admin_sandbox, w.id)
      from cavscope.websites w
      join cavscope.organizations o on o.id = w.organization_id
      left join latest l on l.website_id = w.id
      left join cur c on c.website_id = w.id
      left join cavscope.website_scan_settings ss on ss.website_id = w.id
      left join chg_site cs on cs.website_id = w.id
    ), '[]'::jsonb)
  );
end;
$function$;

revoke all on function public.cavscope_admin_domain_monitor() from public, anon;
grant execute on function public.cavscope_admin_domain_monitor() to authenticated;
