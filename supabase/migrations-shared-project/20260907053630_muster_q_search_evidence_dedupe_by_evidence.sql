-- q_search_evidence joined finding_evidence and emitted one row per
-- evidence/finding link, so a single evidence chunk linked to N open findings
-- consumed N slots of p_limit. Measured on live data: a request for 6 returned
-- 3 distinct evidence rows, each duplicated across findings 4 and 5. An agent
-- asking for 10 pieces of evidence was getting 5.
--
-- Collapse to one row per evidence and return every open finding it supports as
-- finding_ids bigint[], so p_limit now counts distinct evidence and no linkage
-- is lost. similarity is identical across the rows being collapsed (it depends
-- only on the evidence embedding), so max() picks the same value it had.
--
-- Return type changes, so this is a drop and recreate rather than a replace.
-- muster.q_search_evidence carries no explicit grants (it is reached only
-- through the SECURITY DEFINER wrapper below), so nothing needs re-granting.

drop function if exists muster.q_search_evidence(bigint, public.vector, int, float);

create function muster.q_search_evidence(
  p_website_id bigint,
  p_query_embedding public.vector,
  p_limit int default 10,
  p_threshold float default 0.6
)
returns table(evidence_id bigint, finding_ids bigint[], chunk_text text, similarity double precision)
language sql
stable
as $function$
  with scored as (
    select
      se.id as evidence_id,
      fe.finding_id,
      ee.chunk_text,
      (1 - pow(ee.embedding <-> p_query_embedding, 2) / 4)::float as similarity
    from muster.evidence_embeddings ee
    join muster.scan_evidence se on se.id = ee.evidence_id
    join muster.finding_evidence fe on fe.evidence_id = se.id
    join muster.findings f on f.id = fe.finding_id
    where ee.website_id = p_website_id
      and f.status in ('open', 'reopened')
  )
  select
    s.evidence_id,
    array_agg(distinct s.finding_id) as finding_ids,
    s.chunk_text,
    max(s.similarity) as similarity
  from scored s
  where s.similarity >= p_threshold
  group by s.evidence_id, s.chunk_text
  order by similarity desc
  limit p_limit;
$function$;

-- Wrapper named result.finding_id explicitly, so it moves with the shape.
create or replace function public.muster_engine_search_evidence(
  p_ctx jsonb,
  p_website_id bigint,
  p_embedding public.vector,
  p_limit integer default 10,
  p_threshold double precision default 0.6
)
returns jsonb
language plpgsql
security definer
set search_path to 'public, muster'
as $function$
declare
  v_key_org bigint := nullif(p_ctx->>'organization_id', '')::bigint;
  v_org bigint;
begin
  -- Authorization: check scope and org
  if not ('admin' = any (array(select jsonb_array_elements_text(coalesce(p_ctx->'scopes', '[]'::jsonb)))) or
          'read' = any (array(select jsonb_array_elements_text(coalesce(p_ctx->'scopes', '[]'::jsonb))))) then
    raise exception 'key lacks the read scope' using errcode = '42501';
  end if;

  -- Org scope
  select w.organization_id into v_org from muster.websites w where w.id = p_website_id;
  if v_org is null then
    raise exception 'website not found' using errcode = '42704';
  end if;
  if v_key_org is not null and v_org <> v_key_org then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  -- Search and return
  return coalesce(
    jsonb_agg(jsonb_build_object(
      'evidence_id', result.evidence_id,
      'finding_ids', result.finding_ids,
      'chunk_text', result.chunk_text,
      'similarity', result.similarity
    ) order by result.similarity desc),
    '[]'::jsonb
  ) from muster.q_search_evidence(p_website_id, p_embedding, p_limit, p_threshold) result;
end;
$function$;
