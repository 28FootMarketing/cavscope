-- Wire muster.embedding_queue into the embedding pipeline, and give it the one
-- job that justifies its existence: catching CONTENT CHANGES, which nothing
-- currently catches.
--
-- State before this migration:
--   * Triggers were INSERT-only, so the queue held exactly the same information
--     as "rows lacking an embedding" -- no new signal, which is why nothing
--     consuming it was survivable.
--   * The queue carries UNIQUE (entity_type, entity_id) and the triggers used
--     `on conflict do nothing`. Once a row was processed, that entity could
--     never be re-queued again for the rest of its life. The queue was
--     structurally incapable of representing a re-embed.
--   * insert_*_embedding used `on conflict ... do nothing`, so even a correct
--     re-queue would have been a silent no-op against the stale vector.
--   * Nothing drained it: 16 rows, all unprocessed.
--
-- The gap that mattered: an edited finding keeps its stale embedding forever.
-- Neither mechanism saw it -- the queue because it is INSERT-only, the sweep
-- because an embedding does exist. Measured at the time of writing, 4 of 13
-- findings were already stale: updated 2026-09-07 18:15 by a rescan, embedded
-- 05:22. Search was answering from text that no longer matched the finding.
--
-- Deliberately SQL-only. muster-backfill-embeddings already calls
-- get_*_without_embeddings and insert_*_embedding, so widening what those mean
-- wires the queue with no change to the edge function and no redeploy.

-- 1. Re-queueing must reopen an existing row, not be discarded by the unique key.
create or replace function muster.queue_finding_for_embedding()
returns trigger language plpgsql set search_path to ''
as $function$
begin
  insert into muster.embedding_queue (entity_type, entity_id)
  values ('finding', new.id)
  on conflict (entity_type, entity_id)
    do update set processed_at = null, created_at = now();
  return new;
end;
$function$;

create or replace function muster.queue_evidence_for_embedding()
returns trigger language plpgsql set search_path to ''
as $function$
begin
  insert into muster.embedding_queue (entity_type, entity_id)
  values ('evidence', new.id)
  on conflict (entity_type, entity_id)
    do update set processed_at = null, created_at = now();
  return new;
end;
$function$;

-- 2. Enqueue on UPDATE, but only when the embedded text actually changed.
-- A rescan bumps last_seen_at on every finding it re-observes; re-embedding all
-- of them every scan would re-bill the whole corpus for identical text.
create or replace function muster.queue_finding_for_reembedding()
returns trigger language plpgsql set search_path to ''
as $function$
begin
  if new.title is distinct from old.title or new.detail is distinct from old.detail then
    insert into muster.embedding_queue (entity_type, entity_id)
    values ('finding', new.id)
    on conflict (entity_type, entity_id)
      do update set processed_at = null, created_at = now();
  end if;
  return new;
end;
$function$;

create or replace function muster.queue_evidence_for_reembedding()
returns trigger language plpgsql set search_path to ''
as $function$
begin
  if new.excerpt is distinct from old.excerpt or new.headers is distinct from old.headers then
    insert into muster.embedding_queue (entity_type, entity_id)
    values ('evidence', new.id)
    on conflict (entity_type, entity_id)
      do update set processed_at = null, created_at = now();
  end if;
  return new;
end;
$function$;

drop trigger if exists trg_requeue_finding_for_embedding on muster.findings;
create trigger trg_requeue_finding_for_embedding
after update on muster.findings
for each row execute function muster.queue_finding_for_reembedding();

drop trigger if exists trg_requeue_evidence_for_embedding on muster.scan_evidence;
create trigger trg_requeue_evidence_for_embedding
after update on muster.scan_evidence
for each row execute function muster.queue_evidence_for_reembedding();

-- 3. "Needs embedding" now means missing OR queued. Same return shape, so the
-- edge function is unchanged. Ordered oldest-queued-first so a backlog drains
-- fairly instead of starving early rows.
create or replace function public.get_findings_without_embeddings(p_limit integer default 10)
returns table(id bigint, title text, detail text, website_id bigint, organization_id bigint)
language sql security definer set search_path to 'public', 'muster', 'pg_temp'
as $function$
  select f.id, f.title, f.detail, f.website_id, f.organization_id
  from muster.findings f
  left join muster.embedding_queue q
    on q.entity_type = 'finding' and q.entity_id = f.id and q.processed_at is null
  where q.id is not null
     or not exists (select 1 from muster.finding_embeddings fe where fe.finding_id = f.id)
  order by coalesce(q.created_at, 'epoch'::timestamptz), f.id
  limit p_limit;
$function$;

create or replace function public.get_evidence_without_embeddings(p_limit integer default 10)
returns table(id bigint, website_id bigint, organization_id bigint, excerpt text, headers jsonb)
language sql security definer set search_path to 'public', 'muster', 'pg_temp'
as $function$
  select se.id, se.website_id, se.organization_id, se.excerpt, se.headers
  from muster.scan_evidence se
  left join muster.embedding_queue q
    on q.entity_type = 'evidence' and q.entity_id = se.id and q.processed_at is null
  where q.id is not null
     or not exists (select 1 from muster.evidence_embeddings ee where ee.evidence_id = se.id)
  order by coalesce(q.created_at, 'epoch'::timestamptz), se.id
  limit p_limit;
$function$;

-- 4. Writing an embedding must REPLACE a stale one, and close out the queue row
-- in the same statement so draining is atomic with the write.
create or replace function public.insert_finding_embedding(
  p_id bigint, p_finding_id bigint, p_organization_id bigint, p_website_id bigint,
  p_chunk_text text, p_chunk_index integer, p_embedding double precision[])
returns void language plpgsql security definer set search_path to 'public', 'muster', 'pg_temp'
as $function$
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

create or replace function public.insert_evidence_embedding(
  p_id bigint, p_evidence_id bigint, p_organization_id bigint, p_website_id bigint,
  p_chunk_text text, p_chunk_index integer, p_embedding double precision[])
returns void language plpgsql security definer set search_path to 'public', 'muster', 'pg_temp'
as $function$
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

revoke all on function public.get_findings_without_embeddings(integer) from public, anon, authenticated;
revoke all on function public.get_evidence_without_embeddings(integer) from public, anon, authenticated;
revoke all on function public.insert_finding_embedding(bigint,bigint,bigint,bigint,text,integer,double precision[]) from public, anon, authenticated;
revoke all on function public.insert_evidence_embedding(bigint,bigint,bigint,bigint,text,integer,double precision[]) from public, anon, authenticated;
grant execute on function public.get_findings_without_embeddings(integer) to service_role;
grant execute on function public.get_evidence_without_embeddings(integer) to service_role;
grant execute on function public.insert_finding_embedding(bigint,bigint,bigint,bigint,text,integer,double precision[]) to service_role;
grant execute on function public.insert_evidence_embedding(bigint,bigint,bigint,bigint,text,integer,double precision[]) to service_role;

-- 5. Close out the backlog this created. Enqueue everything whose embedded text
-- is older than its last content change, and retire queue rows whose entity is
-- gone so the table cannot grow on orphans.
insert into muster.embedding_queue (entity_type, entity_id)
select 'finding', f.id
from muster.findings f
join muster.finding_embeddings fe on fe.finding_id = f.id
where f.updated_at > fe.created_at
on conflict (entity_type, entity_id) do update set processed_at = null, created_at = now();

update muster.embedding_queue q
   set processed_at = now()
 where q.processed_at is null
   and ((q.entity_type = 'finding'  and not exists (select 1 from muster.findings f       where f.id  = q.entity_id))
     or (q.entity_type = 'evidence' and not exists (select 1 from muster.scan_evidence se where se.id = q.entity_id)));
