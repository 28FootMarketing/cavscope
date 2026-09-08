-- muster_046: put the jurisdiction advisory in the SITREP, tied to findings.
--
-- muster.jurisdictions (101 rows) and muster.jurisdiction_laws (46) are the
-- best-sourced data in this system: real obligations, real effective dates,
-- real reference URLs, reviewed and dated. q_jurisdiction_advisory has existed
-- since onboarding and app.html reads it in fourteen places.
--
-- The SITREP -- the thing a client actually receives -- never mentioned any of
-- it. A tenant's country and region were captured at onboarding and then used
-- once.
--
-- What makes this worth more than a list of laws: jurisdiction_laws.rule_ids
-- already maps each law to the MUSTER checks that bear on it. Joining that to
-- the website's open findings turns "these laws apply to you" into "ADA Title
-- III maps to seven accessibility checks and three of them are failing on your
-- site today". That is a legal-exposure view assembled entirely from data that
-- was already here.
--
-- Two deliberate limits:
--
-- 1. The disclaimer is carried through verbatim from q_jurisdiction_advisory
--    and is not softened. MUSTER is not a law firm, this is not legal advice,
--    and a section that names statutes must say so on the same page.
--
-- 2. Informational findings do not count as exposure, exactly as in
--    muster_044. TP-001 listing third-party scripts is an inventory, and a law
--    is not breached by an inventory.

create or replace function muster.q_sitrep_jurisdiction(p_website_id bigint)
returns jsonb
language plpgsql stable security definer set search_path to '' as $function$
declare
  v_country text;
  v_region  text;
  v_adv     jsonb;
  v_laws    jsonb;
begin
  select o.country_code, o.region_code into v_country, v_region
  from muster.websites w
  join muster.organizations o on o.id = w.organization_id
  where w.id = p_website_id;

  -- An organization with no jurisdiction recorded gets an explicit null rather
  -- than a guess. Defaulting to US here would put American statutes in front of
  -- a client who never said they were American.
  if v_country is null or v_country = '' then
    return jsonb_build_object('available', false,
      'reason', 'No country recorded for this organization, so no jurisdiction advisory can be given.');
  end if;

  v_adv := muster.q_jurisdiction_advisory(v_country, v_region, true);

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
          order by muster.severity_rank(fi.severity), fi.rule_id) as open_findings,
        count(*) filter (where fi.severity in ('critical','high')) as bad,
        count(*) filter (where fi.severity in ('medium','low'))    as soft
      from muster.findings fi
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
    'jurisdictions', coalesce(v_adv->'jurisdictions', '[]'::jsonb),
    'laws', v_laws,
    'law_count', jsonb_array_length(v_laws),
    'exposed_count', (select count(*) from jsonb_array_elements(v_laws) e where e->>'status' = 'exposed'),
    'attention_count', (select count(*) from jsonb_array_elements(v_laws) e where e->>'status' = 'attention'),
    'disclaimer', v_adv->'disclaimer');
end;
$function$;

revoke all on function muster.q_sitrep_jurisdiction(bigint) from public;

-- Patch generate_sitrep by rewriting its definition, so this cannot silently
-- revert an unrelated change someone else made to it.
do $$
declare
  v_oid oid;
  v_src text;
begin
  select p.oid into v_oid from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'muster' and p.proname = 'generate_sitrep';
  if v_oid is null then
    raise exception 'muster.generate_sitrep not found';
  end if;

  select prosrc into v_src from pg_proc where oid = v_oid;
  if position('q_sitrep_jurisdiction' in v_src) > 0 then
    raise notice 'generate_sitrep already carries the jurisdiction section';
    return;
  end if;
  if position('''top_findings'', v_top,' in v_src) = 0 then
    raise exception 'generate_sitrep no longer assembles top_findings where expected; do not patch blindly';
  end if;

  execute replace(
    pg_get_functiondef(v_oid),
    '''top_findings'', v_top,',
    '''top_findings'', v_top,' || chr(10) ||
    '      ''jurisdiction'', muster.q_sitrep_jurisdiction(v.website_id),'
  );
end $$;

do $$
declare v_src text;
begin
  select prosrc into v_src from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'muster' and p.proname = 'generate_sitrep';
  if position('q_sitrep_jurisdiction' in v_src) = 0 then
    raise exception 'the generate_sitrep patch did not take';
  end if;
  if position('evidence_index' in v_src) = 0 then
    raise exception 'the patch disturbed the evidence index';
  end if;
end $$;
