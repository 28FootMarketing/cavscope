-- One answer to "where is this site", used by the SITREP and the workspace.
--
-- Until now two functions answered it differently. q_sitrep_jurisdiction (the
-- SITREP's Laws and Standards section) preferred the state the site states
-- about itself -- websites.detected_region_code, read by engine 1.10.0+ off a
-- governing-law clause, a structured-data or printed postal address, or the
-- meta description -- and fell back to the organization's record.
-- q_compliance_posture (the workspace's Laws and Standards panel, and the rows
-- the workspace export lists) read the organization's record only. For a site
-- whose stated state differs from its organization's, the tenant saw one list
-- of laws in the workspace and another in the report on the same site.
--
-- That matters most for the tier sold on client management: one agency
-- organization, many client sites. The organization's location is the
-- agency's office. A Pennsylvania agency auditing a California client's site
-- got Pennsylvania law in the panel and California law in the SITREP.
--
-- cavscope.website_jurisdiction(website_id) now decides, once:
--   1. the site's own detected state, when there is one;
--   2. otherwise the organization's record -- except for a site parked in the
--      admin sandbox organization, whose record is After Today LLC's own
--      address and says nothing about the site, so nothing is assumed;
--   3. no country at all: nothing is assumed either.
-- It returns the place, and location_source {origin, basis, source_url, note}
-- whose note every renderer prints verbatim. Both callers use it, so they
-- cannot disagree again.
--
-- The SITREP's output is unchanged by construction: this migration snapshots
-- q_sitrep_jurisdiction for every website before redefining it and refuses to
-- commit unless every one is identical afterwards. The workspace panel gains
-- location_source and place; for a site with nothing to go on it now lists no
-- laws, as the SITREP does, rather than a global baseline under no location.

create temp table _jur_before as
  select id, cavscope.q_sitrep_jurisdiction(id) as j from cavscope.websites;
create temp table _posture_before as
  select w.id, cavscope.q_compliance_posture(w.id)->'laws' as laws
    from cavscope.websites w join cavscope.organizations o on o.id = w.organization_id
   where not coalesce(o.is_admin_sandbox, false);

create or replace function cavscope.website_jurisdiction(p_website_id bigint)
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
  v_place    text;
begin
  select coalesce(w.detected_country_code, o.country_code), coalesce(w.detected_region_code, o.region_code),
         w.detected_region_code is not null, w.detected_region_basis, w.detected_region_source,
         coalesce(o.is_admin_sandbox, false)
    into v_country, v_region, v_detected, v_basis, v_source, v_sandbox
  from cavscope.websites w
  join cavscope.organizations o on o.id = w.organization_id
  where w.id = p_website_id;

  if not found then
    return jsonb_build_object('available', false, 'reason', 'Website not found.');
  end if;

  -- A sandbox org's location is the scanning workspace's, never the site's.
  -- With nothing detected there is no location to report, so none is assumed.
  if not v_detected and v_sandbox then
    return jsonb_build_object('available', false,
      'reason', 'This site states no location CavScope could detect (no governing-law clause, no postal address in its structured data or text, and no state named in its description), and it was scanned as an ad-hoc audit, not for an organization with a location on record. No jurisdiction is assumed, so no laws are listed.',
      'location_source', jsonb_build_object('origin', 'none'));
  end if;

  -- An organization with no jurisdiction recorded gets an explicit null rather
  -- than a guess. Defaulting to US here would put American statutes in front of
  -- a client who never said they were American.
  if v_country is null or v_country = '' then
    return jsonb_build_object('available', false,
      'reason', 'No country recorded for this organization, so no jurisdiction advisory can be given.');
  end if;

  v_note := case
    when v_detected and v_basis = 'governing_law'    then 'Read from this site''s own governing-law clause.'
    when v_detected and v_basis = 'jsonld_address'   then 'Read from the postal address in this site''s structured data.'
    when v_detected and v_basis = 'postal_address'   then 'Read from a postal address printed on this site.'
    when v_detected and v_basis = 'meta_description' then 'Read from a state named in this site''s description. That is the weakest signal CavScope uses: marketing copy often names where a business works rather than where it is based.'
    when v_detected                                  then 'Read from this site.'
    else 'Taken from this organization''s own record. The site itself states no location CavScope could detect.'
  end;

  select concat_ws(', ',
           (select j.name from cavscope.jurisdictions j where j.code = v_country || '-' || v_region),
           (select j.name from cavscope.jurisdictions j where j.code = v_country))
    into v_place;

  return jsonb_build_object(
    'available', true,
    'country_code', v_country,
    'region_code', v_region,
    'place', nullif(v_place, ''),
    'location_source', jsonb_build_object(
      'origin', case when v_detected then 'website' else 'organization' end,
      'basis', v_basis,
      'source_url', case when v_detected then v_source end,
      'note', v_note));
end;
$function$;

revoke all on function cavscope.website_jurisdiction(bigint) from public, anon, authenticated;

create or replace function cavscope.q_sitrep_jurisdiction(p_website_id bigint)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to ''
as $function$
declare
  v_loc      jsonb;
  v_adv      jsonb;
  v_laws     jsonb;
begin
  -- Where the site is: decided by website_jurisdiction, which the workspace
  -- panel (q_compliance_posture) also calls. Every unavailable path it takes
  -- still carries the residency note, because a section that lists no laws is
  -- the one most easily read as "nothing applies".
  v_loc := cavscope.website_jurisdiction(p_website_id);
  if not coalesce((v_loc->>'available')::boolean, false) then
    return (v_loc - 'place') || jsonb_build_object('residency_note', cavscope.jurisdiction_residency_note(false));
  end if;

  v_adv := cavscope.q_jurisdiction_advisory(v_loc->>'country_code', v_loc->>'region_code', true);

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
    'location_source', v_loc->'location_source',
    'residency_note', cavscope.jurisdiction_residency_note(true),
    'jurisdictions', coalesce(v_adv->'jurisdictions', '[]'::jsonb),
    'laws', v_laws,
    'law_count', jsonb_array_length(v_laws),
    'exposed_count', (select count(*) from jsonb_array_elements(v_laws) e where e->>'status' = 'exposed'),
    'attention_count', (select count(*) from jsonb_array_elements(v_laws) e where e->>'status' = 'attention'),
    'disclaimer', v_adv->'disclaimer');
end;
$function$;

create or replace function cavscope.q_compliance_posture(p_website_id bigint)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to ''
as $function$
declare
  v_loc jsonb;
  v_country text; v_region text; v_parent text; v_codes text[];
  v_scanned boolean; v_laws jsonb;
begin
  -- Same location as the SITREP on this site, from the same function.
  v_loc := cavscope.website_jurisdiction(p_website_id);
  v_scanned := exists (select 1 from cavscope.scans where website_id = p_website_id and status = 'complete');

  if not coalesce((v_loc->>'available')::boolean, false) then
    return jsonb_build_object(
      'website_id', p_website_id, 'available', false, 'reason', v_loc->>'reason',
      'location_source', v_loc->'location_source', 'scanned', v_scanned,
      'laws', '[]'::jsonb,
      'residency_note', cavscope.jurisdiction_residency_note(false),
      'disclaimer', 'Statuses reflect scanner evidence only. "No open findings" means no open scanner finding is on a check mapped to the law. It is not a determination of compliance, and a law with no mapped check is not assessed by the scan at all.');
  end if;

  v_country := v_loc->>'country_code';
  v_region  := v_loc->>'region_code';
  select parent_code into v_parent from cavscope.jurisdictions where code = v_country;
  v_codes := array_remove(array['GLOBAL', v_parent, v_country,
    case when v_region is null then null else v_country || '-' || v_region end], null);

  select coalesce(jsonb_agg(x order by x->>'jurisdiction_rank', x->>'category', x->>'short_name'), '[]'::jsonb)
    into v_laws
  from (
    select jsonb_build_object(
      'law_id', l.id, 'jurisdiction_code', l.jurisdiction_code, 'jurisdiction_rank', array_position(v_codes, l.jurisdiction_code),
      'short_name', l.short_name, 'full_name', l.full_name, 'category', l.category, 'applies_when', l.applies_when,
      'obligations', l.obligations, 'rule_ids', to_jsonb(l.rule_ids), 'reference_url', l.reference_url,
      'open_findings', f.n, 'finding_ids', f.ids,
      'status', case when cardinality(l.rule_ids) = 0 then 'manual_review'
                     when not v_scanned then 'not_scanned'
                     when f.n > 0 then 'evidence_gap' else 'clear' end) as x
    from cavscope.jurisdiction_laws l
    cross join lateral (
      select count(*) as n, coalesce(jsonb_agg(fi.id), '[]'::jsonb) as ids
      from cavscope.findings fi
      where fi.website_id = p_website_id and fi.status in ('open','reopened') and fi.rule_id = any (l.rule_ids)) f
    where l.jurisdiction_code = any (v_codes)) s;

  return jsonb_build_object(
    'website_id', p_website_id, 'available', true, 'country_code', v_country, 'region_code', v_region,
    'place', v_loc->'place', 'location_source', v_loc->'location_source', 'scanned', v_scanned,
    'laws', v_laws,
    'residency_note', cavscope.jurisdiction_residency_note(jsonb_array_length(v_laws) > 0),
    'disclaimer', 'Statuses reflect scanner evidence only. "No open findings" means no open scanner finding is on a check mapped to the law. It is not a determination of compliance, and a law with no mapped check is not assessed by the scan at all.');
end;
$function$;

do $$
declare v_n integer; v_bad text;
begin
  -- The SITREP's section is unchanged on every website.
  select string_agg(b.id::text, ', ') into v_bad
    from _jur_before b where cavscope.q_sitrep_jurisdiction(b.id) is distinct from b.j;
  if v_bad is not null then raise exception 'q_sitrep_jurisdiction changed output for websites %', v_bad; end if;

  -- Every real tenant site lists the same laws it did, because on today's data
  -- each one's detected state is its organization's or absent.
  select string_agg(b.id::text, ', ') into v_bad
    from _posture_before b where cavscope.q_compliance_posture(b.id)->'laws' is distinct from b.laws;
  if v_bad is not null then raise exception 'q_compliance_posture changed its law list for tenant websites %', v_bad; end if;

  -- Both now carry the same location source on every site.
  select count(*) into v_n from cavscope.websites w
   where cavscope.q_compliance_posture(w.id)->'location_source' is distinct from cavscope.q_sitrep_jurisdiction(w.id)->'location_source';
  if v_n > 0 then raise exception '% websites have a different location source in the workspace than in the SITREP', v_n; end if;
end $$;

drop table _jur_before;
drop table _posture_before;
