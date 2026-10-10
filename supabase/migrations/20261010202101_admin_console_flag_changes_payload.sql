-- Settings wiring pass, part 2: the console payload returns the fifteen most recent feature-flag
-- changes from cavscope.platform_audit as flag_changes, so Settings can show who changed which
-- switch. The edit must apply exactly once or the migration aborts.

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

  d := pg_temp.sub(d, '    ''pricing_changes'', (select coalesce(',
    '    ''flag_changes'', (select coalesce(jsonb_agg(jsonb_build_object(
          ''at'', a.at, ''action'', a.action, ''target'', a.target, ''detail'', a.detail,
          ''actor'', (select ac.email from cavscope.users ac where ac.id = a.actor_id)) order by a.at desc), ''[]''::jsonb)
      from (select * from cavscope.platform_audit where action like ''Feature flag%'' order by at desc limit 15) a),

    ''pricing_changes'', (select coalesce(');
  execute d;
end $mig$;
