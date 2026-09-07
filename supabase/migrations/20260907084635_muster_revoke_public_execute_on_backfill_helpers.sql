-- Six SECURITY DEFINER helpers added for the embedding backfill were left
-- executable by PUBLIC, anon and authenticated. They exist only so the
-- muster-backfill-embeddings edge function can reach the muster schema through
-- PostgREST, and that function authenticates with SUPABASE_SERVICE_ROLE_KEY.
-- Nothing else should ever call them.
--
-- Read exposure: get_findings_without_embeddings and get_evidence_without_embeddings
-- return id, title, detail, website_id and organization_id with NO organization
-- filter, so an anonymous caller could read every tenant's findings.
--
-- Write exposure, and the more serious one: insert_finding_embedding and
-- insert_evidence_embedding perform an unconditional insert into
-- muster.finding_embeddings / muster.evidence_embeddings with caller-supplied
-- organization_id, website_id, chunk_text and embedding. Anonymous callers could
-- therefore write arbitrary rows into any tenant's retrieval index.
--
-- That is not just data tampering. muster-agent's search_findings and
-- search_evidence read those rows and hand chunk_text to the model as retrieved
-- evidence. A crafted embedding that ranks highly for common queries, carrying
-- attacker-chosen chunk_text, is indirect prompt injection into the agent from an
-- unauthenticated endpoint.
--
-- Driven off proname so the signatures cannot be got wrong.

do $$
declare
  r record;
  n int := 0;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p join pg_namespace nsp on nsp.oid = p.pronamespace
    where nsp.nspname = 'public' and p.prokind = 'f'
      and p.proname in (
        'insert_finding_embedding', 'insert_evidence_embedding',
        'get_findings_without_embeddings', 'get_evidence_without_embeddings',
        'count_findings_without_embeddings', 'count_evidence_without_embeddings'
      )
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', r.sig);
    execute format('grant execute on function %s to service_role', r.sig);
    n := n + 1;
  end loop;
  raise notice 'locked down % backfill helper(s)', n;
end $$;
