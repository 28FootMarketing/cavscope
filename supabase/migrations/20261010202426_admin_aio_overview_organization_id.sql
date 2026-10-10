-- AI Readiness, part 2: each site row carries organization_id so the console's organization filter
-- applies to it. Edits the function from part 1 in place; each edit must apply exactly once or the
-- migration aborts.

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
  where n.nspname = 'public' and p.proname = 'cavscope_admin_aio_overview';

  d := pg_temp.sub(d, 'select w.id, w.name, w.url, o.name as org, o.is_admin_sandbox as sandbox,',
                      'select w.id, w.name, w.url, o.name as org, o.id as org_id, o.is_admin_sandbox as sandbox,');
  d := pg_temp.sub(d, 'select c.id, c.name, c.url, c.org, c.sandbox,', 'select c.id, c.name, c.url, c.org, c.org_id, c.sandbox,');
  d := pg_temp.sub(d, 'group by c.id, c.name, c.url, c.org, c.sandbox,', 'group by c.id, c.name, c.url, c.org, c.org_id, c.sandbox,');
  d := pg_temp.sub(d, '''website_id'', p.id, ''website'', p.name,', '''website_id'', p.id, ''organization_id'', p.org_id, ''website'', p.name,');
  execute d;
end $mig$;
