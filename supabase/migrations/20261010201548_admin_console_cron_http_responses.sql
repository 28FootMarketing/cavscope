-- System Health wiring pass (admin.html).
--
-- A cron job that calls an edge function (cron_safe_post -> net.http_post) reports "succeeded" as
-- soon as the request is queued, whether or not the function answered, so the Scheduled jobs table
-- and the "Scheduled Jobs" status row could read healthy while every function call was failing.
-- Postgres keeps the HTTP answers it recorded for those calls (net._http_response, a few hours of
-- them); the console payload now returns their count, how many were not a 2xx/3xx (a 4xx, a 5xx or
-- no answer), when the window starts and when the last failure was, as cron_http.
-- The edit must apply exactly once or the migration aborts.

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

  d := pg_temp.sub(d, '    ''integrations'', jsonb_build_object(',
    '    ''cron_http'', (select jsonb_build_object(
          ''total'', count(*),
          ''failed'', count(*) filter (where r.status_code is null or r.status_code >= 400),
          ''since'', min(r.created),
          ''last_failed_at'', max(r.created) filter (where r.status_code is null or r.status_code >= 400))
        from net._http_response r),

    ''integrations'', jsonb_build_object(');
  execute d;
end $mig$;
