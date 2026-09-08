-- The six public RPCs the retrieval subsystem runs on. They were missed by
-- muster_019/muster_020 because those selected shims by the name prefix
-- 'muster%', and these six do not carry it. The "70/70 shims" checksum was
-- therefore true and useless at the same time: it verified the set it had
-- defined, not the set the system needs.
--
-- Without these, muster-backfill-embeddings 404s on every call and the 77 rows
-- currently sitting in muster.embedding_queue never become vectors, which means
-- semantic search over findings and evidence quietly returns nothing.
--
-- Grants match source: service_role only. These read tenant data across all
-- organizations with SECURITY DEFINER and no org scoping, because the backfill
-- worker is platform-level. anon and authenticated must never reach them.
set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.count_evidence_without_embeddings()
 RETURNS bigint
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'muster', 'pg_temp'
AS $function$
  select count(*)
  from muster.scan_evidence se
  where not exists (
    select 1 from muster.evidence_embeddings ee where ee.evidence_id = se.id
  );
$function$;

CREATE OR REPLACE FUNCTION public.count_findings_without_embeddings()
 RETURNS bigint
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'muster', 'pg_temp'
AS $function$
  select count(*)
  from muster.findings f
  where not exists (
    select 1 from muster.finding_embeddings fe where fe.finding_id = f.id
  );
$function$;

CREATE OR REPLACE FUNCTION public.get_evidence_without_embeddings(p_limit integer DEFAULT 10)
 RETURNS TABLE(id bigint, website_id bigint, organization_id bigint, excerpt text, headers jsonb)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'muster', 'pg_temp'
AS $function$
  select se.id, se.website_id, se.organization_id, se.excerpt, se.headers
  from muster.scan_evidence se
  left join muster.embedding_queue q
    on q.entity_type = 'evidence' and q.entity_id = se.id and q.processed_at is null
  where q.id is not null
     or not exists (select 1 from muster.evidence_embeddings ee where ee.evidence_id = se.id)
  order by coalesce(q.created_at, 'epoch'::timestamptz), se.id
  limit p_limit;
$function$;

CREATE OR REPLACE FUNCTION public.get_findings_without_embeddings(p_limit integer DEFAULT 10)
 RETURNS TABLE(id bigint, title text, detail text, website_id bigint, organization_id bigint)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'muster', 'pg_temp'
AS $function$
  select f.id, f.title, f.detail, f.website_id, f.organization_id
  from muster.findings f
  left join muster.embedding_queue q
    on q.entity_type = 'finding' and q.entity_id = f.id and q.processed_at is null
  where q.id is not null
     or not exists (select 1 from muster.finding_embeddings fe where fe.finding_id = f.id)
  order by coalesce(q.created_at, 'epoch'::timestamptz), f.id
  limit p_limit;
$function$;

CREATE OR REPLACE FUNCTION public.insert_evidence_embedding(p_id bigint, p_evidence_id bigint, p_organization_id bigint, p_website_id bigint, p_chunk_text text, p_chunk_index integer, p_embedding double precision[])
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'muster', 'pg_temp'
AS $function$
begin
  insert into muster.evidence_embeddings (id, evidence_id, organization_id, website_id, chunk_text, chunk_index, embedding)
  values (p_id, p_evidence_id, p_organization_id, p_website_id, p_chunk_text, p_chunk_index, p_embedding::public.vector)
  on conflict (evidence_id, chunk_index) do update
    set chunk_text = excluded.chunk_text,
        embedding  = excluded.embedding,
        created_at = now();

  update muster.embedding_queue
     set processed_at = now()
   where entity_type = 'evidence' and entity_id = p_evidence_id and processed_at is null;
end;
$function$;

CREATE OR REPLACE FUNCTION public.insert_finding_embedding(p_id bigint, p_finding_id bigint, p_organization_id bigint, p_website_id bigint, p_chunk_text text, p_chunk_index integer, p_embedding double precision[])
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'muster', 'pg_temp'
AS $function$
begin
  insert into muster.finding_embeddings (id, finding_id, organization_id, website_id, chunk_text, chunk_index, embedding)
  values (p_id, p_finding_id, p_organization_id, p_website_id, p_chunk_text, p_chunk_index, p_embedding::public.vector)
  on conflict (finding_id, chunk_index) do update
    set chunk_text = excluded.chunk_text,
        embedding  = excluded.embedding,
        created_at = now();

  update muster.embedding_queue
     set processed_at = now()
   where entity_type = 'finding' and entity_id = p_finding_id and processed_at is null;
end;
$function$;

revoke all on function public.count_evidence_without_embeddings() from public, anon, authenticated;
revoke all on function public.count_findings_without_embeddings() from public, anon, authenticated;
revoke all on function public.get_evidence_without_embeddings(integer) from public, anon, authenticated;
revoke all on function public.get_findings_without_embeddings(integer) from public, anon, authenticated;
revoke all on function public.insert_evidence_embedding(bigint, bigint, bigint, bigint, text, integer, double precision[]) from public, anon, authenticated;
revoke all on function public.insert_finding_embedding(bigint, bigint, bigint, bigint, text, integer, double precision[]) from public, anon, authenticated;
grant execute on function public.count_evidence_without_embeddings() to service_role;
grant execute on function public.count_findings_without_embeddings() to service_role;
grant execute on function public.get_evidence_without_embeddings(integer) to service_role;
grant execute on function public.get_findings_without_embeddings(integer) to service_role;
grant execute on function public.insert_evidence_embedding(bigint, bigint, bigint, bigint, text, integer, double precision[]) to service_role;
grant execute on function public.insert_finding_embedding(bigint, bigint, bigint, bigint, text, integer, double precision[]) to service_role;
