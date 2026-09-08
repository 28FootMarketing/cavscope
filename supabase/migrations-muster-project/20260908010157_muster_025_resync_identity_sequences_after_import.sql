-- Rows were imported with their original ids, so every identity sequence on
-- this project is still sitting at 1. Without this, the first insert into any
-- migrated table collides with an existing primary key. This is the step that
-- makes a copied database usable rather than merely populated.
--
-- Driven off pg_get_serial_sequence so it covers identity and serial columns
-- alike, and is safe to re-run.
do $$
declare
  r record;
  v_seq text;
  v_max bigint;
begin
  for r in
    select c.relname as tbl, a.attname as col
    from pg_attribute a
    join pg_class c on c.oid = a.attrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'muster' and c.relkind = 'r'
      and a.attnum > 0 and not a.attisdropped
      and (a.attidentity <> '' or pg_get_serial_sequence('muster.' || quote_ident(c.relname), a.attname) is not null)
  loop
    v_seq := pg_get_serial_sequence('muster.' || quote_ident(r.tbl), r.col);
    if v_seq is null then continue; end if;
    execute format('select coalesce(max(%I), 0) from muster.%I', r.col, r.tbl) into v_max;
    -- is_called = false when the table is empty, so the sequence yields 1 next
    -- rather than 2; true otherwise so it yields max+1.
    perform setval(v_seq, greatest(v_max, 1), v_max > 0);
  end loop;
end $$;
