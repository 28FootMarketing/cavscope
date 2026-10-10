-- AI Readiness section of the Super Admin Console (admin.html).
--
-- The section was a "not instrumented" stub saying there is no assessment, no scoring rules and no
-- findings category for AI readiness. That has been false since 2026-09-23: nine engine rules drive
-- the workspace's AIO view. This function gives the console the same view across every site: one
-- row per site with the nine checks on its latest completed HTTP scan, judged exactly as the
-- workspace judges them (app.html Live.buildAio): a check is a pass only if its rule could have
-- fired -- the rule is active, the scan's engine is at or past the release that first emitted it,
-- and the engine was not told the homepage went unread (AVAIL-001/003/004). Anything else is 'na'
-- (not assessed) and is left out of the index. Citability is never scored.
-- Super admin only; anon has no execute grant.

create or replace function public.cavscope_admin_aio_overview()
 returns jsonb
 language plpgsql
 stable
 security definer
 set search_path to ''
as $function$
begin
  if not cavscope.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;

  return (
    with defs(ord, rule, pillar, floor, always) as (values
      (1, 'GOV-008',  'crawl',  '1.8.0', false),
      (2, 'GOV-001',  'crawl',  null,    false),
      (3, 'GOV-002',  'crawl',  null,    false),
      (4, 'A11Y-002', 'entity', null,    false),
      (5, 'GOV-003',  'entity', null,    false),
      (6, 'GOV-005',  'entity', null,    false),
      (7, 'GOV-007',  'schema', '1.8.0', false),
      (8, 'GOV-006',  'llms',   '1.8.0', false),
      (9, 'GOV-004',  'aibots', null,    true)
    ),
    sites as (
      select w.id, w.name, w.url, o.name as org, o.is_admin_sandbox as sandbox,
             sc.id as scan_id, sc.engine_version, sc.finished_at,
             exists (select 1 from cavscope.findings u
                      where u.website_id = w.id and u.status in ('open', 'reopened')
                        and u.rule_id in ('AVAIL-001', 'AVAIL-003', 'AVAIL-004')) as unread
        from cavscope.websites w
        join cavscope.organizations o on o.id = w.organization_id
        left join lateral (
          select s.id, s.engine_version, s.finished_at
            from cavscope.scans s
           where s.website_id = w.id and s.status = 'complete' and s.engine = 'http_native'
           order by s.finished_at desc nulls last limit 1) sc on true
    ),
    cells as (
      select s.*, d.ord, d.rule, d.pillar,
             case
               when s.scan_id is null then 'na'
               when s.unread then 'na'
               when not coalesce(r.active, false) then 'na'
               when d.floor is not null and not coalesce(
                      string_to_array(substring(s.engine_version from '\d+\.\d+\.\d+'), '.')::int[]
                        >= string_to_array(d.floor, '.')::int[], false) then 'na'
               when d.always then case when f.id is null then 'na'
                                       when f.detail ~* 'unaddressed' then 'fail' else 'pass' end
               when f.id is not null then 'fail'
               else 'pass'
             end as state,
             left(f.detail, 200) as detail
        from sites s
        cross join defs d
        left join cavscope.scan_rules r on r.rule_id = d.rule
        left join lateral (
          select x.id, x.detail from cavscope.findings x
           where x.website_id = s.id and x.rule_id = d.rule and x.status in ('open', 'reopened') limit 1) f on true
    ),
    per_site as (
      select c.id, c.name, c.url, c.org, c.sandbox, c.scan_id, c.engine_version, c.finished_at, c.unread,
             count(*) filter (where c.state = 'pass') as passed,
             count(*) filter (where c.state <> 'na') as assessed,
             jsonb_agg(jsonb_build_object('rule', c.rule, 'state', c.state, 'detail', c.detail) order by c.ord) as checks
        from cells c
       group by c.id, c.name, c.url, c.org, c.sandbox, c.scan_id, c.engine_version, c.finished_at, c.unread
    )
    select jsonb_build_object(
      'rules', (select jsonb_agg(jsonb_build_object('rule', d.rule, 'pillar', d.pillar, 'floor', d.floor,
                                                    'title', r.title, 'active', coalesce(r.active, false)) order by d.ord)
                  from defs d left join cavscope.scan_rules r on r.rule_id = d.rule),
      'sites', coalesce((select jsonb_agg(jsonb_build_object(
                  'website_id', p.id, 'website', p.name, 'url', p.url, 'organization', p.org, 'sandbox', p.sandbox,
                  'scan_id', p.scan_id, 'engine_version', p.engine_version, 'scanned_at', p.finished_at,
                  'unread', p.unread, 'passed', p.passed, 'assessed', p.assessed,
                  'index', case when p.assessed > 0 then round(100.0 * p.passed / p.assessed)::int end,
                  'checks', p.checks)
                  order by p.sandbox, case when p.assessed > 0 then round(100.0 * p.passed / p.assessed) end nulls last, p.name)
                from per_site p), '[]'::jsonb)
    )
  );
end;
$function$;

revoke all on function public.cavscope_admin_aio_overview() from public, anon;
grant execute on function public.cavscope_admin_aio_overview() to authenticated;
