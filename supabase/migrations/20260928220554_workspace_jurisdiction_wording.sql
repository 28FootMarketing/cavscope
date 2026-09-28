-- The workspace's two jurisdiction surfaces stop reading as determinations,
-- and carry the same residency note every SITREP has carried since
-- 20260928215356.
--
-- 1. q_compliance_posture (the workspace's per-law panel, and the rows the
--    workspace export lists as controls). Its disclaimer read: '"clear"
--    means no open scanner finding maps to the law', and app.html printed
--    the raw status beside each law, so a tenant saw FTC Act Section 5:
--    clear -- the exact word the SITREP's jurisdiction section is forbidden
--    to render, on the same data. The status KEYS are unchanged
--    (evidence_gap / clear / not_scanned / manual_review), because they are
--    keys and app.html maps them to labels; only the sentence a person reads
--    changes. It also gains residency_note.
--
-- 2. public.muster_jurisdiction_advisory (onboarding's country/region
--    preview, headed "What applies to you" in app.html). It gains
--    residency_note, listed form when the advisory names any law.
--
-- NOT changed here, deliberately: q_compliance_posture still reads the
-- organization's own country/region and ignores websites.detected_region_*,
-- so for a tenant whose site states a different state than its org record,
-- the workspace panel and that site's SITREP list different laws. Aligning
-- them changes which laws a tenant sees and is a decision, not a wording fix.

create or replace function cavscope.q_compliance_posture(p_website_id bigint)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to ''
as $function$
declare
  v_country text; v_region text; v_parent text; v_codes text[];
  v_scanned boolean; v_laws jsonb;
begin
  select o.country_code, o.region_code into v_country, v_region
  from cavscope.websites w join cavscope.organizations o on o.id = w.organization_id where w.id = p_website_id;
  select parent_code into v_parent from cavscope.jurisdictions where code = v_country;
  v_codes := array_remove(array['GLOBAL', v_parent, v_country,
    case when v_region is null then null else v_country || '-' || v_region end], null);
  v_scanned := exists (select 1 from cavscope.scans where website_id = p_website_id and status = 'complete');

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
    'website_id', p_website_id, 'country_code', v_country, 'region_code', v_region, 'scanned', v_scanned,
    'laws', v_laws,
    'residency_note', cavscope.jurisdiction_residency_note(jsonb_array_length(v_laws) > 0),
    'disclaimer', 'Statuses reflect scanner evidence only. "No open findings" means no open scanner finding is on a check mapped to the law. It is not a determination of compliance, and a law with no mapped check is not assessed by the scan at all.');
end;
$function$;

create or replace function public.muster_jurisdiction_advisory(p_country_code text, p_region_code text default null::text, p_depth text default 'summary'::text)
 returns jsonb
 language sql
 stable security definer
 set search_path to ''
as $function$
  select a || jsonb_build_object('residency_note',
           cavscope.jurisdiction_residency_note(coalesce((a->>'law_count')::integer, 0) > 0))
  from (select cavscope.q_jurisdiction_advisory(p_country_code, p_region_code,
          p_depth = 'full' and (select auth.uid()) is not null) as a) s;
$function$;

do $$
declare v_out jsonb;
begin
  select cavscope.q_compliance_posture(w.id) into v_out from cavscope.websites w limit 1;
  if v_out is not null then
    if coalesce(v_out->>'residency_note', '') = '' then raise exception 'compliance posture carries no residency_note'; end if;
    if v_out->>'disclaimer' ~* '"clear"|\mclear\M' then raise exception 'compliance posture disclaimer still says clear'; end if;
  end if;
  v_out := public.muster_jurisdiction_advisory('US', 'PA', 'summary');
  if coalesce(v_out->>'residency_note', '') not like 'Location is not the whole picture.%' then
    raise exception 'jurisdiction advisory carries no listed-form residency_note';
  end if;
end $$;
