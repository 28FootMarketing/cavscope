-- A per-site location an administrator sets, which beats detection.
--
-- cavscope.website_jurisdiction (20260929033108) resolves a site's location
-- from what the site states about itself, falling back to its organization's
-- record. Detection is a heuristic over a governing-law clause, a structured-
-- data or printed address, or -- weakest -- a state named in the meta
-- description, and it has been wrong on a real site: After Today's own was
-- read as Washington state off "Anthony Washington Sr." (engine 1.14.0 fixed
-- that case narrowly, and says so). For an agency's client, the agency may
-- simply know better than anything on the page. Until now the only remedy for
-- a wrong or missing detection was to change the site.
--
-- websites.jurisdiction_override_* now carries a location a super admin set,
-- with who, when and an optional reason. The resolver takes it first -- for a
-- sandbox site too, which is how an ad-hoc audit of a site that states no
-- location gets a law list at all -- and its location_source says, in the
-- words every renderer prints: "Set by a CavScope administrator on <date>, in
-- place of what the site states." The engine never writes these columns, so a
-- rescan cannot undo an override.
--
-- public.muster_admin_site_jurisdictions() lists every site with its
-- detection, its override and the resolved result, plus the country and region
-- catalogue for the form; public.muster_admin_set_site_jurisdiction() sets or
-- clears one. Both are SECURITY DEFINER, check cavscope.is_super_admin()
-- themselves, and are granted to authenticated only, anon revoked by name, like
-- every other muster_admin_* RPC. Every set and clear writes an activity event
-- on the site's organization.
--
-- Existing SITREPs are documents and are not rewritten; the next scan's report
-- carries the override. The workspace panel reads it on the next load.

create temp table _jur_before as
  select id, cavscope.q_sitrep_jurisdiction(id) as j from cavscope.websites;

alter table cavscope.websites
  add column if not exists jurisdiction_override_country text,
  add column if not exists jurisdiction_override_region  text,
  add column if not exists jurisdiction_override_note    text,
  add column if not exists jurisdiction_override_by      bigint references cavscope.users(id) on delete set null,
  add column if not exists jurisdiction_override_at      timestamptz;

alter table cavscope.websites drop constraint if exists websites_jurisdiction_override_shape;
alter table cavscope.websites add constraint websites_jurisdiction_override_shape check (
  (jurisdiction_override_country is null and jurisdiction_override_region is null
     and jurisdiction_override_note is null and jurisdiction_override_at is null)
  or (jurisdiction_override_country is not null and jurisdiction_override_at is not null
     and coalesce(length(jurisdiction_override_note), 0) <= 300));

comment on column cavscope.websites.jurisdiction_override_country is
  'Country a super admin set for this site, taking precedence over detected_* and the organization record in cavscope.website_jurisdiction. Written only by muster_admin_set_site_jurisdiction; the engine never touches it.';

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
  v_ovr_country text;
  v_ovr_region  text;
  v_ovr_note    text;
  v_ovr_at      timestamptz;
  v_override    boolean := false;
begin
  select coalesce(w.detected_country_code, o.country_code), coalesce(w.detected_region_code, o.region_code),
         w.detected_region_code is not null, w.detected_region_basis, w.detected_region_source,
         coalesce(o.is_admin_sandbox, false),
         w.jurisdiction_override_country, w.jurisdiction_override_region, w.jurisdiction_override_note, w.jurisdiction_override_at
    into v_country, v_region, v_detected, v_basis, v_source, v_sandbox,
         v_ovr_country, v_ovr_region, v_ovr_note, v_ovr_at
  from cavscope.websites w
  join cavscope.organizations o on o.id = w.organization_id
  where w.id = p_website_id;

  if not found then
    return jsonb_build_object('available', false, 'reason', 'Website not found.');
  end if;

  -- An administrator's override beats everything the site says and the
  -- organization's record, including for a sandbox site: it is a person with
  -- evidence overriding a heuristic. Its region is taken as set, null included,
  -- never topped up from the detected one.
  if v_ovr_country is not null then
    v_override := true;
    v_country := v_ovr_country; v_region := v_ovr_region;
    v_detected := false; v_basis := null; v_source := null;
  end if;

  -- A sandbox org's location is the scanning workspace's, never the site's.
  -- With nothing detected there is no location to report, so none is assumed.
  if not v_override and not v_detected and v_sandbox then
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
    when v_override then format('Set by a CavScope administrator on %s, in place of what the site states.', to_char(v_ovr_at at time zone 'UTC', 'YYYY-MM-DD'))
                         || coalesce(' Reason: ' || nullif(btrim(v_ovr_note), '') || case when btrim(v_ovr_note) ~ '[.!?]$' then '' else '.' end, '')
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
      'origin', case when v_override then 'override' when v_detected then 'website' else 'organization' end,
      'basis', v_basis,
      'source_url', case when v_detected then v_source end,
      'note', v_note));
end;
$function$;

create or replace function public.muster_admin_site_jurisdictions()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to ''
as $function$
begin
  if not cavscope.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  return jsonb_build_object(
    'sites', coalesce((
      select jsonb_agg(jsonb_build_object(
        'website_id', w.id, 'name', w.name, 'url', w.url,
        'organization_id', o.id, 'organization', o.name, 'sandbox', coalesce(o.is_admin_sandbox, false),
        'org_location', nullif(concat_ws('-', o.country_code, o.region_code), ''),
        'detected', case when w.detected_country_code is null then null else jsonb_build_object(
          'country', w.detected_country_code, 'region', w.detected_region_code,
          'basis', w.detected_region_basis, 'source_url', w.detected_region_source) end,
        'override', case when w.jurisdiction_override_country is null then null else jsonb_build_object(
          'country', w.jurisdiction_override_country, 'region', w.jurisdiction_override_region,
          'note', w.jurisdiction_override_note, 'set_at', w.jurisdiction_override_at,
          'set_by', (select u.name from cavscope.users u where u.id = w.jurisdiction_override_by)) end,
        'resolved', cavscope.website_jurisdiction(w.id))
        order by coalesce(o.is_admin_sandbox, false), o.name, w.name)
      from cavscope.websites w join cavscope.organizations o on o.id = w.organization_id), '[]'::jsonb),
    'countries', coalesce((select jsonb_agg(jsonb_build_object('code', j.code, 'name', j.name) order by j.name)
                  from cavscope.jurisdictions j where j.kind = 'country'), '[]'::jsonb),
    'regions', coalesce((select jsonb_agg(jsonb_build_object(
                    'country', split_part(j.code, '-', 1), 'code', substring(j.code from position('-' in j.code) + 1), 'name', j.name)
                  order by j.name)
                  from cavscope.jurisdictions j where j.kind = 'region'), '[]'::jsonb));
end;
$function$;

create or replace function public.muster_admin_set_site_jurisdiction(
  p_website_id bigint, p_country text, p_region text default null, p_note text default null)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  v_org     bigint;
  v_country text := nullif(upper(btrim(coalesce(p_country, ''))), '');
  v_region  text := nullif(upper(btrim(coalesce(p_region, ''))), '');
  v_note    text := nullif(btrim(coalesce(p_note, '')), '');
  v_action  text;
  v_detail  text;
begin
  if not cavscope.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;

  select w.organization_id into v_org from cavscope.websites w where w.id = p_website_id;
  if not found then raise exception 'website % not found', p_website_id using errcode = 'P0002'; end if;

  if v_country is null then
    update cavscope.websites set
      jurisdiction_override_country = null, jurisdiction_override_region = null,
      jurisdiction_override_note = null, jurisdiction_override_by = null, jurisdiction_override_at = null
     where id = p_website_id;
    v_action := 'Jurisdiction override cleared';
    v_detail := 'The site''s location is read from the site and its organization again.';
  else
    if not exists (select 1 from cavscope.jurisdictions j where j.code = v_country and j.kind = 'country') then
      raise exception 'unknown country code %', v_country using errcode = '22023';
    end if;
    if v_region is not null and not exists (
      select 1 from cavscope.jurisdictions j where j.code = v_country || '-' || v_region and j.kind = 'region') then
      raise exception 'unknown region % for country %', v_region, v_country using errcode = '22023';
    end if;
    if length(v_note) > 300 then raise exception 'reason is longer than 300 characters' using errcode = '22001'; end if;
    update cavscope.websites set
      jurisdiction_override_country = v_country, jurisdiction_override_region = v_region,
      jurisdiction_override_note = v_note, jurisdiction_override_by = cavscope.current_user_id(),
      jurisdiction_override_at = now()
     where id = p_website_id;
    v_action := 'Jurisdiction override set';
    v_detail := format('Location set to %s%s.%s', v_country, coalesce('-' || v_region, ''), coalesce(' Reason: ' || v_note, ''));
  end if;

  insert into cavscope.activity_events (organization_id, entity_type, entity_id, action, detail, actor_id)
  values (v_org, 'website', p_website_id, v_action, v_detail, cavscope.current_user_id());

  return cavscope.website_jurisdiction(p_website_id);
end;
$function$;

revoke all on function public.muster_admin_site_jurisdictions() from public, anon;
revoke all on function public.muster_admin_set_site_jurisdiction(bigint, text, text, text) from public, anon;
grant execute on function public.muster_admin_site_jurisdictions() to authenticated;
grant execute on function public.muster_admin_set_site_jurisdiction(bigint, text, text, text) to authenticated;

do $$
declare v_bad text; v_id bigint; v_probe jsonb; v_sitrep jsonb; v_acl text;
begin
  -- No override is set yet, so every report is exactly what it was.
  select string_agg(b.id::text, ', ') into v_bad
    from _jur_before b where cavscope.q_sitrep_jurisdiction(b.id) is distinct from b.j;
  if v_bad is not null then raise exception 'q_sitrep_jurisdiction changed output for websites %', v_bad; end if;

  -- An override wins, on a sandbox site with nothing detected, and flows into
  -- the SITREP. Probed on a real row and rolled back.
  select w.id into v_id from cavscope.websites w join cavscope.organizations o on o.id = w.organization_id
   where o.is_admin_sandbox and w.detected_region_code is null limit 1;
  if v_id is not null then
    begin
      update cavscope.websites set jurisdiction_override_country = 'US', jurisdiction_override_region = 'CA',
             jurisdiction_override_note = 'probe', jurisdiction_override_at = now() where id = v_id;
      v_probe := cavscope.website_jurisdiction(v_id);
      v_sitrep := cavscope.q_sitrep_jurisdiction(v_id);
      raise exception using message = 'override_probe_rollback';
    exception when others then
      if sqlerrm <> 'override_probe_rollback' then raise; end if;
    end;
    if v_probe->>'region_code' is distinct from 'CA' or v_probe->'location_source'->>'origin' is distinct from 'override' then
      raise exception 'override did not win: %', v_probe;
    end if;
    if v_probe->'location_source'->>'note' not like 'Set by a CavScope administrator on %Reason: probe.' then
      raise exception 'override note wrong: %', v_probe->'location_source'->>'note';
    end if;
    -- The SITREP carries the advisory's full region code (US-CA), the resolver the short one (CA).
    if not coalesce((v_sitrep->>'available')::boolean, false) or v_sitrep->>'region_code' is distinct from 'US-CA' then
      raise exception 'SITREP did not follow the override: %', v_sitrep->>'region_code';
    end if;
    if exists (select 1 from cavscope.websites where id = v_id and jurisdiction_override_country is not null) then
      raise exception 'probe override was not rolled back';
    end if;
  end if;

  -- Neither admin RPC is reachable anonymously.
  select string_agg(p.proname || '=' || coalesce(p.proacl::text, ''), '; ') into v_acl
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname in ('muster_admin_site_jurisdictions', 'muster_admin_set_site_jurisdiction')
     and coalesce(p.proacl::text, '') ~ 'anon=';
  if v_acl is not null then raise exception 'admin jurisdiction RPC executable by anon: %', v_acl; end if;
end $$;

drop table _jur_before;
