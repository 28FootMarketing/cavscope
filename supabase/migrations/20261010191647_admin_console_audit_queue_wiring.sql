-- Audit Queue wiring pass (admin.html).
--
-- The Audit Queue's "Recent scans" panel promised the most recent runs and asked the page for
-- 50, but the console payload returned 8, out of 260 scans on file, and the nav badge counted
-- those 8. recent_scans now returns 50, and each row carries the engine and engine_version that
-- ran it (there are two engines now, and a browser scan was indistinguishable from an HTTP one)
-- and, for a failed scan, the first 300 characters of why. system.queue gains `stalled`: scans
-- queued or running for over 30 minutes. Only queued scans were ever aged, so a hung engine
-- with a scan stuck in `running` read as healthy.
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

  -- recent_scans: 50 rows (it was 8, while the Audit Queue panel promised the most recent runs),
  -- with the engine that ran each one and, for a failed scan, why.
  d := pg_temp.sub(d, '''http_status'', s.http_status, ''response_ms'', s.response_ms,',
    '''http_status'', s.http_status, ''response_ms'', s.response_ms,
            ''engine'', s.engine, ''engine_version'', s.engine_version,
            ''error'', left(s.error_message, 300),');
  d := pg_temp.sub(d, '        order by coalesce(s.finished_at, s.started_at, s.queued_at, s.created_at) desc
        limit 8) r),',
    '        order by coalesce(s.finished_at, s.started_at, s.queued_at, s.created_at) desc
        limit 50) r),');

  -- queue: a scan queued or running for over 30 minutes is stalled. Running scans were never
  -- aged, so a hung engine read as healthy.
  d := pg_temp.sub(d, '''oldest_queued_at'', (select min(queued_at) from cavscope.scans where status = ''queued'')),',
    '''oldest_queued_at'', (select min(queued_at) from cavscope.scans where status = ''queued''),
        ''stalled'', (select count(*) from cavscope.scans where status in (''queued'', ''running'')
                       and coalesce(started_at, queued_at, created_at) < now() - interval ''30 minutes'')),');
  execute d;
end $mig$;
