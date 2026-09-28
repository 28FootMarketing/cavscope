-- The SITREP's Laws and Standards section says, in every report, that its
-- list is chosen by location and that laws can also apply through where a
-- site's customers live.
--
-- WHY. q_sitrep_jurisdiction picks laws by ONE place: the state the site
-- states about itself (engine 1.10.0+) or, for a real tenant, the
-- organization's own record. That answers "what is commonly relevant to an
-- organization based here". It does not answer "what applies to this site",
-- because a large share of privacy law is keyed to the people whose data is
-- collected, not to the business. On 2026-09-28 a Pennsylvania site's list
-- was thirteen entries with no CCPA and no GDPR, and the report said nothing
-- about why. A Pennsylvania business selling to California residents at
-- CCPA's thresholds, or to people in the EU, can be inside both. Read cold,
-- a list of laws under a client's name reads as "these are the ones", and
-- the absence of CCPA reads as "CCPA does not apply". That is absence read
-- as a determination, the same family as absence-of-findings-as-a-pass.
--
-- WHAT. cavscope.jurisdiction_residency_note(p_listed) returns one of two
-- fixed paragraphs: p_listed true when laws are listed ("this list is chosen
-- by location..."), false when none are ("no laws listed does not mean none
-- apply..."). q_sitrep_jurisdiction emits it as `residency_note` on every
-- return path, including both available:false ones, because a report that
-- lists no laws is the one most easily read as "nothing applies". Every
-- renderer (sitrep_jurisdiction_md, sitrep.html, app.html) prints it
-- verbatim, so the words are decided once, here.
--
-- The two examples (CCPA, GDPR Art. 3(2)) are stated as "can reach", with
-- the condition that makes them reach. They are illustrations of the
-- principle, not a determination for any client; whether either applies
-- depends on thresholds and facts the scan cannot see, and the section's
-- own disclaimer already routes that to counsel.
--
-- Reports generated before this migration carry no residency_note and
-- print nothing new; the next scan's report carries it.

create or replace function cavscope.jurisdiction_residency_note(p_listed boolean)
 returns text
 language sql
 immutable
 set search_path to ''
as $function$
  select case when p_listed then
    'Location is not the whole picture. This list is chosen by where the organization is located, but many privacy and consumer-protection laws apply according to where the people whose data a site collects live. '
  else
    'No laws being listed does not mean none apply. Many privacy and consumer-protection laws apply according to where the people whose data a site collects live, not where the organization is based. '
  end
  || 'For example, California''s CCPA can reach a business based elsewhere that meets its thresholds for California residents, and the EU''s GDPR can reach an organization outside the EU that offers goods or services to people in the EU or monitors their behavior. '
  || case when p_listed then
    'CavScope cannot see where this site''s visitors or customers are, so laws that could apply through them are not listed here.'
  else
    'CavScope cannot see where this site''s visitors or customers are, so it cannot say which of these apply.'
  end;
$function$;

revoke all on function cavscope.jurisdiction_residency_note(boolean) from public, anon, authenticated;

create or replace function cavscope.q_sitrep_jurisdiction(p_website_id bigint)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to ''
as $function$
declare
  v_country  text;
  v_region   text;
  v_detected boolean;
  v_basis    text;
  v_source   text;
  v_sandbox  boolean;
  v_note     text;
  v_origin   jsonb;
  v_adv      jsonb;
  v_laws     jsonb;
begin
  select coalesce(w.detected_country_code, o.country_code), coalesce(w.detected_region_code, o.region_code),
         w.detected_region_code is not null, w.detected_region_basis, w.detected_region_source,
         coalesce(o.is_admin_sandbox, false)
    into v_country, v_region, v_detected, v_basis, v_source, v_sandbox
  from cavscope.websites w
  join cavscope.organizations o on o.id = w.organization_id
  where w.id = p_website_id;

  -- A sandbox org's location is the scanning workspace's, never the site's.
  -- With nothing detected there is no location to report, so none is assumed.
  if not v_detected and v_sandbox then
    return jsonb_build_object('available', false,
      'reason', 'This site states no location CavScope could detect (no governing-law clause, no postal address in its structured data or text, and no state named in its description), and it was scanned as an ad-hoc audit, not for an organization with a location on record. No jurisdiction is assumed, so no laws are listed.',
      'location_source', jsonb_build_object('origin', 'none'),
      'residency_note', cavscope.jurisdiction_residency_note(false));
  end if;

  -- An organization with no jurisdiction recorded gets an explicit null rather
  -- than a guess. Defaulting to US here would put American statutes in front of
  -- a client who never said they were American.
  if v_country is null or v_country = '' then
    return jsonb_build_object('available', false,
      'reason', 'No country recorded for this organization, so no jurisdiction advisory can be given.',
      'residency_note', cavscope.jurisdiction_residency_note(false));
  end if;

  v_note := case
    when v_detected and v_basis = 'governing_law'    then 'Read from this site''s own governing-law clause.'
    when v_detected and v_basis = 'jsonld_address'   then 'Read from the postal address in this site''s structured data.'
    when v_detected and v_basis = 'postal_address'   then 'Read from a postal address printed on this site.'
    when v_detected and v_basis = 'meta_description' then 'Read from a state named in this site''s description. That is the weakest signal CavScope uses: marketing copy often names where a business works rather than where it is based.'
    when v_detected                                  then 'Read from this site.'
    else 'Taken from this organization''s own record. The site itself states no location CavScope could detect.'
  end;
  v_origin := jsonb_build_object(
    'origin', case when v_detected then 'website' else 'organization' end,
    'basis', v_basis,
    'source_url', case when v_detected then v_source end,
    'note', v_note);

  v_adv := cavscope.q_jurisdiction_advisory(v_country, v_region, true);

  select coalesce(jsonb_agg(law order by law->>'short_name'), '[]'::jsonb)
  into v_laws
  from (
    select l || jsonb_build_object(
      'open_findings', coalesce(f.open_findings, '[]'::jsonb),
      'status', case
                  when coalesce(f.bad, 0) > 0 then 'exposed'
                  when coalesce(f.soft, 0) > 0 then 'attention'
                  else 'clear'
                end
    ) as law
    from jsonb_array_elements(coalesce(v_adv->'laws', '[]'::jsonb)) as l
    left join lateral (
      select
        jsonb_agg(jsonb_build_object(
          'finding_id', fi.id, 'rule_id', fi.rule_id,
          'severity', fi.severity, 'title', fi.title)
          order by cavscope.severity_rank(fi.severity), fi.rule_id) as open_findings,
        count(*) filter (where fi.severity in ('critical','high')) as bad,
        count(*) filter (where fi.severity in ('medium','low'))    as soft
      from cavscope.findings fi
      where fi.website_id = p_website_id
        and fi.status in ('open','reopened')
        and fi.rule_id::text in (
          select jsonb_array_elements_text(coalesce(l->'rule_ids', '[]'::jsonb))
        )
    ) f on true
  ) x;

  return jsonb_build_object(
    'available', true,
    'country_code', v_adv->'country_code',
    'region_code', v_adv->'region_code',
    'location_source', v_origin,
    'residency_note', cavscope.jurisdiction_residency_note(true),
    'jurisdictions', coalesce(v_adv->'jurisdictions', '[]'::jsonb),
    'laws', v_laws,
    'law_count', jsonb_array_length(v_laws),
    'exposed_count', (select count(*) from jsonb_array_elements(v_laws) e where e->>'status' = 'exposed'),
    'attention_count', (select count(*) from jsonb_array_elements(v_laws) e where e->>'status' = 'attention'),
    'disclaimer', v_adv->'disclaimer');
end;
$function$;

-- sitrep_jurisdiction_md: print residency_note in both branches. Patched in
-- place, for the reason 20260928213959 gives: the live definition has
-- drifted from its only file (082), and re-creating it from that file would
-- silently undo a branding rewrite. Each anchor must occur exactly once.
do $$
declare
  v_def     text;
  v_unavail text := $a$    return v_md || coalesce(p_jur->>'reason', 'No jurisdiction is recorded for this organization, so no laws are listed.') || E'\n';$a$;
  v_unavail_new text := $n$    return v_md || coalesce(p_jur->>'reason', 'No jurisdiction is recorded for this organization, so no laws are listed.') || E'\n'
      || coalesce(E'\n' || (p_jur->>'residency_note') || E'\n', '');$n$;
  v_listed  text := $a$  if n_open + n_none + n_na = 0 then$a$;
  v_listed_ins text := $i$  if p_jur->>'residency_note' is not null then
    v_md := v_md || E'\n' || (p_jur->>'residency_note') || E'\n';
  end if;
$i$;
begin
  select pg_get_functiondef('cavscope.sitrep_jurisdiction_md(jsonb)'::regprocedure) into v_def;
  if position('residency_note' in v_def) > 0 then
    raise exception 'sitrep_jurisdiction_md already prints residency_note; refusing to patch twice';
  end if;
  if (length(v_def) - length(replace(v_def, v_unavail, ''))) / length(v_unavail) <> 1 then
    raise exception 'sitrep_jurisdiction_md: unavailable-branch anchor not found exactly once; refusing to patch';
  end if;
  if (length(v_def) - length(replace(v_def, v_listed, ''))) / length(v_listed) <> 1 then
    raise exception 'sitrep_jurisdiction_md: listed-branch anchor not found exactly once; refusing to patch';
  end if;
  v_def := replace(v_def, v_unavail, v_unavail_new);
  v_def := replace(v_def, v_listed, v_listed_ins || v_listed);
  execute v_def;
end $$;

do $$
declare v_out jsonb; v_md text;
begin
  -- Every path carries the note: a listed report, a sandbox site with nothing
  -- detected, and a real org with no country on record.
  select cavscope.q_sitrep_jurisdiction(w.id) into v_out
    from cavscope.websites w where w.detected_region_code is not null limit 1;
  if v_out is not null and coalesce(v_out->>'residency_note', '') not like 'Location is not the whole picture.%' then
    raise exception 'a listed jurisdiction carries no residency_note';
  end if;
  select cavscope.q_sitrep_jurisdiction(w.id) into v_out
    from cavscope.websites w join cavscope.organizations o on o.id = w.organization_id
   where o.is_admin_sandbox and w.detected_region_code is null limit 1;
  if v_out is not null and coalesce(v_out->>'residency_note', '') not like 'No laws being listed does not mean none apply.%' then
    raise exception 'an unavailable jurisdiction carries no residency_note';
  end if;

  -- The markdown prints it in both branches.
  v_md := cavscope.sitrep_jurisdiction_md(jsonb_build_object('available', false, 'reason', 'r',
            'residency_note', cavscope.jurisdiction_residency_note(false)));
  if position('No laws being listed does not mean none apply.' in v_md) = 0 then
    raise exception 'markdown drops residency_note when no laws are listed';
  end if;
  v_md := cavscope.sitrep_jurisdiction_md(jsonb_build_object('available', true, 'laws', '[]'::jsonb,
            'residency_note', cavscope.jurisdiction_residency_note(true)));
  if position('Location is not the whole picture.' in v_md) = 0 then
    raise exception 'markdown drops residency_note when laws are listed';
  end if;
  -- And a payload without it (a report from before this migration) prints nothing new.
  v_md := cavscope.sitrep_jurisdiction_md(jsonb_build_object('available', false, 'reason', 'r'));
  if position('whole picture' in v_md) > 0 or position('does not mean none apply' in v_md) > 0 then
    raise exception 'markdown invents a residency note for a payload without one';
  end if;
end $$;
