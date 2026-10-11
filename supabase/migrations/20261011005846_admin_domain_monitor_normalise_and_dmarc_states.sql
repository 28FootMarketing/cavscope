-- Corrections to cavscope_admin_domain_monitor() found by running it against the live evidence.
--
-- 1. CAA arrives as ONE line, its records joined by ' | ' in whatever order the resolver answered, each led by
--    the name it was found at. The first version compared sorted lines, so a resolver that merely reordered the
--    same four records read as a change: 10 false changes on one site in 30 days. The name is now stripped, the
--    line split on newline and ' | ', and the pieces sorted.
-- 2. Each change now says whether the scan engine version also changed at that scan ('engine_changed'). A record
--    that appears at the instant a release changed what the engine captures may be a capture change, not a DNS
--    change, and the page says so beside it.
-- 3. DMARC state 'none' (a record with p=none) was ambiguous next to every other field's 'none' (no record). A
--    DMARC record whose policy is none is monitoring only: the state is now 'monitor'. 'missing' still means
--    no record, 'quarantine' and 'reject' enforce.
--
-- Edited in place, each step asserted to match exactly once.
do $mig$
declare
  v_def text := pg_get_functiondef('public.cavscope_admin_domain_monitor()'::regprocedure);
  n int;
  steps text[][] := array[
    array[$a$select s.website_id, s.id as scan_id, s.finished_at,$a$,
          $b$select s.website_id, s.id as scan_id, s.finished_at, s.engine_version,$b$],
    array[$a$from regexp_split_to_table(e.excerpt, E'\n') l$a$,
          $b$from regexp_split_to_table(case when e.kind = 'dns_caa' then regexp_replace(e.excerpt, '(^|\n)[^\s:]+: ', '\1', 'g') else e.excerpt end, E'\n| \\| ') l$b$],
    array[$a$select website_id, scan_id, finished_at, field, coalesce($a$,
          $b$select website_id, scan_id, finished_at, engine_version, field, coalesce($b$],
    array[$a$group by website_id, scan_id, finished_at, field$a$,
          $b$group by website_id, scan_id, finished_at, engine_version, field$b$],
    array[$a$select t.website_id, t.field, t.finished_at, t.prev_value, t.value$a$,
          $b$select t.website_id, t.field, t.finished_at, t.prev_value, t.value, t.engine_version, t.prev_engine$b$],
    array[$a$lag(p.value) over (partition by p.website_id, p.field order by p.scan_id) as prev_value$a$,
          $b$lag(p.value) over (partition by p.website_id, p.field order by p.scan_id) as prev_value,
                       lag(p.engine_version) over (partition by p.website_id, p.field order by p.scan_id) as prev_engine$b$],
    array[$a$'from', left(r.prev_value, 160), 'to', left(r.value, 160))$a$,
          $b$'from', left(r.prev_value, 160), 'to', left(r.value, 160),
                         'engine_changed', r.engine_version is distinct from r.prev_engine)$b$],
    array[$a$coalesce(lower(substring(v from '(?i)(?:^|[ ;])p=([a-z]+)')), 'unknown')$a$,
          $b$case lower(substring(v from '(?i)(?:^|[ ;])p=([a-z]+)')) when 'none' then 'monitor' when 'quarantine' then 'quarantine' when 'reject' then 'reject' else 'unknown' end$b$]
  ];
  i int;
begin
  for i in 1 .. array_length(steps, 1) loop
    n := (length(v_def) - length(replace(v_def, steps[i][1], ''))) / greatest(length(steps[i][1]), 1);
    if n <> 1 then raise exception 'step %: expected exactly 1 match, found %', i, n; end if;
    v_def := replace(v_def, steps[i][1], steps[i][2]);
  end loop;
  execute v_def;
end
$mig$;
