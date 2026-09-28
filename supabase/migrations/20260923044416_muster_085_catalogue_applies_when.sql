-- MUSTER 083: two catalogue repairs the SITREP's Laws and Standards section exposed.
--
-- Migration 082 started rendering muster.jurisdiction_laws in every SITREP, with
-- each law's applies_when shown as the condition under which it applies. That put
-- two pieces of catalogue data in front of clients for the first time.
--
-- 1. applies_when on every ai_governance row (ids 47-129, 83 rows) was a raw tag
--    list, e.g. "Covers: highrisk, companion, text, media". A borough manager
--    reading "Applies when: Covers: media" learns nothing, and the one thing the
--    field must convey is lost: every one of these applies ONLY if the
--    organization uses AI in a particular way. Most clients reading a SITREP do
--    not, and the section is the one most likely to be read as legal exposure.
--
--    The tags are defined nowhere in this repo or schema; the rows arrived as
--    data. Their meaning is read off the laws that carry them:
--      companion  companion and conversational chatbot laws (e.g. ids 52-62)
--      media      deepfake, likeness and AI-content labelling laws (e.g. 119-127)
--      highrisk   AI in hiring, housing, insurance, health and credit (e.g. 75-78, 94-96)
--      text       generative-AI and general AI-use laws -- but also algorithmic
--                 pricing (103, 104), which is not about text. So `text` is
--                 rendered as broad public-facing AI use, not as "generates text";
--                 the narrower reading would under-state where those two apply.
--
--    Rewritten as one sentence in a fixed order, broadest last, as a semicolon
--    list when a row carries more than one tag. The mapping is
--    one phrase per tag, so the tag set of every row is recoverable from the new
--    text; only the original tag order is not, and it carried no meaning.
--    reviewed_at is NOT touched: it records when the legal content was reviewed,
--    and this changes presentation, not the law.
--
-- 2. BPINA's reference_url ended "act=0094." -- a trailing period that makes the
--    act number invalid. Act 94 of 2005 is the Breach of Personal Information
--    Notification Act, so the period is removed. Not click-tested: the sandbox
--    this was written from cannot reach legis.state.pa.us.
--
-- Scope is asserted, not assumed: an unmapped tag aborts before any write, and
-- every row outside the two repairs must hash identically before and after.

do $$
declare
  v_unknown text;
  v_before  text;
  v_ids     text;
  v_n       int;
begin
  select string_agg(distinct t, ', ') into v_unknown
    from muster.jurisdiction_laws l,
         unnest(string_to_array(substr(l.applies_when, length('Covers: ') + 1), ', ')) t
   where l.applies_when like 'Covers: %'
     and t not in ('highrisk', 'companion', 'media', 'text');
  if v_unknown is not null then
    raise exception 'unmapped coverage tag(s): %; add a phrase before rewriting', v_unknown;
  end if;

  -- The rewrite targets rows by their text; the untouched-rows check below
  -- excludes them by id. Those two only describe the same set if the tagged rows
  -- are exactly ids 47-129, so say so rather than rely on it.
  select string_agg(id::text, ',' order by id) into v_ids
    from muster.jurisdiction_laws where applies_when like 'Covers: %';
  if v_ids is distinct from (select string_agg(g::text, ',' order by g) from generate_series(47, 129) g) then
    raise exception 'tagged rows are not exactly ids 47-129: %', v_ids;
  end if;

  select md5(string_agg(l::text, '|' order by l.id)) into v_before
    from muster.jurisdiction_laws l
   where l.id <> 18 and l.id not between 47 and 129;

  with tagged as (
    select l.id, string_to_array(substr(l.applies_when, length('Covers: ') + 1), ', ') tags
      from muster.jurisdiction_laws l
     where l.applies_when like 'Covers: %'
  ), phrased as (
    select t.id, array_agg(p.phrase order by p.ord) phrases
      from tagged t
      join (values
        (1, 'companion', 'offers a conversational or companion chatbot'),
        (2, 'media',     'creates or publishes AI-generated or AI-altered images, audio or video'),
        (3, 'highrisk',  'uses AI to make or support significant decisions about people, such as hiring, lending, housing, insurance, health care or education'),
        (4, 'text',      'uses AI in the products, services or content it offers to the public')
      ) p(ord, tag, phrase) on p.tag = any(t.tags)
     group by t.id
  )
  update muster.jurisdiction_laws l
     set applies_when = case
       when cardinality(ph.phrases) = 1 then 'Only if the organization ' || ph.phrases[1] || '.'
       -- Semicolons, because the highrisk phrase carries its own comma list and a
       -- comma-joined sentence ran "... or education, or uses AI in ..." together.
       else 'Only if the organization does any of these: '
            || array_to_string(ph.phrases[1:cardinality(ph.phrases) - 1], '; ')
            || '; or ' || ph.phrases[cardinality(ph.phrases)] || '.'
     end
    from phrased ph
   where ph.id = l.id;
  get diagnostics v_n = row_count;
  if v_n <> 83 then
    raise exception 'expected to rewrite 83 applies_when values, rewrote %', v_n;
  end if;

  update muster.jurisdiction_laws
     set reference_url = rtrim(reference_url, '.')
   where id = 18 and short_name = 'BPINA' and reference_url like '%act=0094.';
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'expected to repair 1 BPINA reference_url, repaired %', v_n;
  end if;

  if exists (select 1 from muster.jurisdiction_laws where applies_when like 'Covers:%') then
    raise exception 'a raw coverage tag list survived';
  end if;
  if exists (select 1 from muster.jurisdiction_laws where reference_url ~ '[.,;:)]$') then
    raise exception 'a reference_url still ends in punctuation';
  end if;

  -- Nothing else moved. The rewritten rows are excluded by id, not by the text
  -- they now hold, so a rewrite cannot hide itself from this check.
  if v_before is distinct from (
    select md5(string_agg(l::text, '|' order by l.id))
      from muster.jurisdiction_laws l
     where l.id <> 18 and l.id not between 47 and 129
  ) then
    raise exception 'rows outside the two repairs changed';
  end if;

  -- And the rendered section reads as a sentence for the site that found it.
  if muster.sitrep_jurisdiction_md(
       muster.sitrep_jurisdiction_assess(muster.q_sitrep_jurisdiction(11), false)) like '%Covers:%' then
    raise exception 'the YMCA section still renders a raw tag list';
  end if;

  raise notice 'catalogue repaired: 83 applies_when rewritten, BPINA reference fixed';
end $$;
