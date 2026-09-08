-- Second half of the muster_015 transcription repair. muster_016 fixed
-- do_add_website (now byte-identical to source) but under-corrected
-- q_compliance_posture: source carries NO backslashes at all in the
-- disclaimer -- it is a plain "clear" inside a single-quoted string -- while
-- this project still had one before each quote.
--
-- Same technique as muster_016: read the definition back from the catalog and
-- strip, rather than restating the body.
do $$
declare d text;
begin
  select pg_get_functiondef(p.oid) into d
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'muster' and p.proname = 'q_compliance_posture';
  execute replace(d, chr(92), '');
end $$;
