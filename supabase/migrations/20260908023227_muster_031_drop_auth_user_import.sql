-- Drops the temporary endpoint muster_030 created, now that the three
-- auth.users rows and their three auth.identities rows are in place and
-- verified byte-identical to the source project:
--   auth.users      md5 a2876dbd50c2001eb4e017fc63975aed
--   auth.identities md5 1ea187cec0977a5313e6f0a923f5c406
--
-- The token in muster_030 is dead from this point. It is left in that file
-- rather than scrubbed, for the same reason muster_023's is: this directory is
-- a history, and editing history to look tidier is how a ledger stops being
-- trustworthy. Do not reuse the value.

drop function if exists public.muster_auth_import(text, jsonb, jsonb);

do $$
begin
  if exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'muster_auth_import'
  ) then
    raise exception 'muster_auth_import still present after drop';
  end if;
end $$;
