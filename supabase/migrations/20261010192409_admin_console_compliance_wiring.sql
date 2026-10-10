-- Compliance wiring pass (admin.html).
--
-- 1. The unassessed bucket counted `assessment is null`, but the column cannot be null: it holds
--    not_assessed, not_met, partial, met or not_applicable. So a not_assessed control (what
--    sync_controls writes for a reference whose only checks have not run) was in `total` and in no
--    bar, and the bars would not add up the day a browser-only reference appeared. The bucket is
--    now not_assessed, with not_applicable counted separately.
-- 2. The headline rate was met / total, which silently scored an unassessed control as a failure.
--    It is now met / assessed (met + partial + not_met), and `assessed` is returned.
-- 3. The page says "derived from scanner evidence" but the counts included the 2 manual controls a
--    person entered. The headline, the by-framework table and the "controls not met" action item
--    now count source = 'derived' only; the manual count is returned separately as `manual`.
-- 4. compliance_by_framework: the same population, per framework (14 frameworks on file).
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
declare d text;
begin
  select pg_get_functiondef(p.oid) into d
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'cavscope_admin_console';

  -- Headline: scanner-derived controls only; the unassessed bucket matches the values the column
  -- can hold; the rate is met over ASSESSED, so an unassessed control counts as neither met nor failed.
  d := pg_temp.sub(d, '          ''unassessed'', count(*) filter (where c.assessment is null),
          ''total'', count(*),
          ''rate'', case when count(*) = 0 then null
                       else round(100.0 * count(*) filter (where c.assessment = ''met'') / count(*))::integer end)
        from cavscope.controls c
        join cavscope.websites w on w.id = c.website_id
        join cavscope.organizations o on o.id = w.organization_id and not o.is_admin_sandbox),',
    '          ''unassessed'', count(*) filter (where c.assessment = ''not_assessed''),
          ''not_applicable'', count(*) filter (where c.assessment = ''not_applicable''),
          ''total'', count(*),
          ''assessed'', count(*) filter (where c.assessment in (''met'', ''partial'', ''not_met'')),
          ''manual'', (select count(*) from cavscope.controls c2
                         join cavscope.websites w2 on w2.id = c2.website_id
                         join cavscope.organizations o2 on o2.id = w2.organization_id and not o2.is_admin_sandbox
                        where c2.source = ''manual''),
          ''rate'', case when count(*) filter (where c.assessment in (''met'', ''partial'', ''not_met'')) = 0 then null
                       else round(100.0 * count(*) filter (where c.assessment = ''met'')
                                  / count(*) filter (where c.assessment in (''met'', ''partial'', ''not_met'')))::integer end)
        from cavscope.controls c
        join cavscope.websites w on w.id = c.website_id
        join cavscope.organizations o on o.id = w.organization_id and not o.is_admin_sandbox
        where c.source = ''derived''),');

  -- By framework, same population.
  d := pg_temp.sub(d, '    ''role_changes'', (select coalesce(',
    '    ''compliance_by_framework'', (select coalesce(jsonb_agg(jsonb_build_object(
          ''framework'', x.framework, ''label'', cavscope.framework_label(x.framework),
          ''met'', x.met, ''partial'', x.partial, ''not_met'', x.not_met, ''unassessed'', x.unassessed, ''total'', x.total)
          order by x.total desc, x.framework), ''[]''::jsonb)
      from (select c.framework,
                   count(*) as total,
                   count(*) filter (where c.assessment = ''met'') as met,
                   count(*) filter (where c.assessment = ''partial'') as partial,
                   count(*) filter (where c.assessment = ''not_met'') as not_met,
                   count(*) filter (where c.assessment in (''not_assessed'', ''not_applicable'')) as unassessed
              from cavscope.controls c
              join cavscope.websites w on w.id = c.website_id
              join cavscope.organizations o on o.id = w.organization_id and not o.is_admin_sandbox
             where c.source = ''derived''
             group by c.framework) x),

    ''role_changes'', (select coalesce(');

  -- The action item says "derived from scanner evidence", so count only derived controls.
  d := pg_temp.sub(d, 'where c.assessment = ''not_met''),
          ''Controls assessed not met''',
    'where c.assessment = ''not_met'' and c.source = ''derived''),
          ''Controls assessed not met''');
  execute d;
end $mig$;
