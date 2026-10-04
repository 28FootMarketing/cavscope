-- Eight SQL functions still said "MUSTER" in strings or comments. Two of the strings reach customers:
-- cavscope_admin_impersonate_start and _end write the activity line a tenant reads when a CavScope
-- administrator opens or closes a support session on their account ("A MUSTER super admin opened a
-- read-only support session for this account"). The rest were an error shown to a super admin,
-- a Vault secret description, the sandbox organization's name when it has to be created, and comments.
--
-- Rewritten in place with CREATE OR REPLACE from each function's own definition, so signature, security
-- definer, search_path and grants are exactly what they were; only the word changes. The block raises
-- if it touches anything other than the eight it was written for. Lowercase identifiers (tier=muster,
-- muster-agent) are not touched: they name live things that the rename plan retires in order.

do $$
declare r record; d text; n int := 0;
begin
  for r in
    select p.oid, p.proname
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where p.prokind = 'f' and ns.nspname in ('cavscope', 'public')
      and pg_get_functiondef(p.oid) like '%MUSTER%'
  loop
    d := replace(pg_get_functiondef(r.oid), 'MUSTER', 'CavScope');
    execute d;
    n := n + 1;
  end loop;
  if n <> 8 then raise exception 'expected 8 functions, rewrote %', n; end if;
end $$;
