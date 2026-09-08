-- Eight functions from the retrieval work were created with
--   SET search_path TO 'public, muster'
-- which Postgres stores as search_path="public, muster": ONE quoted identifier
-- naming a schema that does not exist, not two schemas. Neither public nor
-- muster is actually on the path inside these functions.
--
-- The six backfill helpers got away with it because they only reference
-- schema-qualified objects. The two search wrappers did not: pgvector's <->
-- operator lives in public and is looked up unqualified, so every call failed
-- with "operator does not exist: public.vector <-> public.vector". That means
-- search_findings and search_evidence were both broken end to end through the
-- agent gateway, independently of whether any embeddings existed.
--
-- Correct form quotes each identifier separately, or leaves them bare. Compare
-- public.agency_refresh_kpis in this same database, which correctly carries
-- search_path=public, "28footmarketing". pg_temp is pinned last so a temp
-- object cannot shadow a lookup in these SECURITY DEFINER functions.
--
-- Driven off the malformed setting itself rather than a hardcoded list, so it
-- corrects exactly the functions that carry it and is a no-op on re-run. This
-- must therefore run AFTER any migration that recreates one of them.

do $$
declare
  r record;
  n int := 0;
begin
  for r in
    select distinct p.oid::regprocedure as sig
    from pg_proc p
    cross join lateral unnest(p.proconfig) as cfg
    where cfg = 'search_path="public, muster"'
  loop
    execute format('alter function %s set search_path = public, muster, pg_temp', r.sig);
    n := n + 1;
  end loop;
  raise notice 'repaired search_path on % function(s)', n;
end $$;
