-- q_search_evidence scored with (1 - L2) while q_search_findings scored with
-- (1 - L2^2 / 4). Both take the same p_threshold default of 0.6, so the two
-- tools were measuring on different scales against one cutoff.
--
-- For normalised embeddings L2^2 = 2 - 2*cos, so genuinely related text (cos
-- ~0.8) sits at L2 ~0.63. Under (1 - L2) that scores 0.37 and under
-- (1 - L2^2/4) it scores 0.90. Only near-identical text cleared 0.6 on the old
-- formula, so search_evidence returned nothing for real queries -- measured at
-- 0.12 for a top-ranked real match before this change.
--
-- Adopt the findings formula so both tools share one [0,1] scale where a
-- self-match is 1.0 and the 0.6 default means the same thing in both.
--
-- Known and NOT changed here: the finding_evidence join emits one row per
-- evidence/finding link, so evidence attached to N open findings consumes N of
-- p_limit. Asking for 6 returns 3 distinct evidence rows when each is linked
-- twice. Fixing that changes the return contract, so it is left for a decision.

create or replace function muster.q_search_evidence(
  p_website_id bigint,
  p_query_embedding public.vector,
  p_limit int default 10,
  p_threshold float default 0.6
)
returns table(evidence_id bigint, finding_id bigint, chunk_text text, similarity double precision)
language sql
stable
as $function$
  select
    se.id,
    fe.finding_id,
    ee.chunk_text,
    (1 - pow(ee.embedding <-> p_query_embedding, 2) / 4)::float as similarity
  from muster.evidence_embeddings ee
  join muster.scan_evidence se on se.id = ee.evidence_id
  join muster.finding_evidence fe on fe.evidence_id = se.id
  join muster.findings f on f.id = fe.finding_id
  where ee.website_id = p_website_id
    and f.status in ('open', 'reopened')
    and (1 - pow(ee.embedding <-> p_query_embedding, 2) / 4)::float >= p_threshold
  order by similarity desc
  limit p_limit;
$function$;
