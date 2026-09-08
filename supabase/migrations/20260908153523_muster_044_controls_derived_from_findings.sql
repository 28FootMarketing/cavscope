-- muster_044: the control register maintains itself from findings.
--
-- muster.controls held two rows. Both were hand-seeded on one website in
-- September and neither had been touched since, while the pricing page sells
-- "control and framework mapping" and the workspace has a Controls view. The
-- mapping a client actually sees is real -- it comes from
-- scan_rules.framework_refs and appears on every finding and SITREP -- so this
-- table was a second, empty implementation of something that already worked.
--
-- This makes the table a projection of that same data, so the register fills
-- itself and cannot drift from the findings it claims to summarise.
--
-- Three decisions worth keeping:
--
-- 1. It does NOT restate the standard. Putting a slightly-wrong rendering of
--    a SOC 2 or GDPR control in front of a client is the expensive failure in
--    a compliance product, and MUSTER is not the authority on those texts. The
--    title is the reference; the description says which MUSTER checks touch it
--    and states plainly that this is coverage of the public web surface only,
--    not a control assessment.
--
-- 2. A row a human wrote is never overwritten. controls.source defaults to
--    'manual', so the two existing rows keep their titles, their owners and
--    their assessments. Sync only ever writes rows it owns.
--
-- 3. Compound references are split. framework_refs stores "Art. 6, Art. 7" and
--    "CCPA 1798.130, CalOPPA" as one string because it is display text. A
--    register keyed on a reference needs one row per reference, so the sync
--    splits on commas. It also reclassifies CUSTOM values that begin "WCAG "
--    into the WCAG framework, which is where A11Y-006 and A11Y-007 put their
--    4.1.2 mapping because framework_refs is a jsonb object and cannot hold
--    the WCAG key twice.

alter table muster.controls
  add column if not exists source varchar(16) not null default 'manual';

alter table muster.controls
  drop constraint if exists controls_source_check;
alter table muster.controls
  add constraint controls_source_check check (source in ('manual', 'derived'));

comment on column muster.controls.source is
  'manual = written by a person and never touched by sync_controls; derived = projected from scan_rules.framework_refs by muster.sync_controls().';

-- Every (framework, reference) a rule maps to, one row per reference, with the
-- rules that map to it. This is the shape the register is built from.
create or replace function muster.rule_control_refs()
returns table (framework text, reference text, rule_id text)
language sql stable set search_path to '' as $function$
  select
    -- CUSTOM entries whose value names a WCAG success criterion belong under
    -- WCAG. Everything else keeps its key. RFCs and MUSTER's own themes
    -- ("AIO readiness", "Crawl governance") legitimately stay CUSTOM: there is
    -- no standards body column for them and inventing one would be worse.
    case when t.k = 'CUSTOM' and trim(ref.r) like 'WCAG %' then 'WCAG' else t.k end,
    case when t.k = 'CUSTOM' and trim(ref.r) like 'WCAG %'
         then trim(substring(trim(ref.r) from 6))
         else trim(ref.r) end,
    r.rule_id::text
  from muster.scan_rules r,
       lateral jsonb_each_text(r.framework_refs) as t(k, v),
       lateral unnest(string_to_array(t.v, ',')) as ref(r)
  where r.active and trim(ref.r) <> '';
$function$;

-- Rebuild the derived rows for one website. Idempotent: safe to call after
-- every scan, and calling it twice changes nothing.
create or replace function muster.sync_controls(p_website_id bigint)
returns integer
language plpgsql security definer set search_path to '' as $function$
declare
  v_scans integer;
  v_written integer := 0;
begin
  select count(*) into v_scans
  from muster.scans where website_id = p_website_id and status = 'complete';

  with refs as (
    select framework, reference, array_agg(distinct rule_id order by rule_id) as rules
    from muster.rule_control_refs()
    group by framework, reference
  ),
  scored as (
    select
      r.framework, r.reference, r.rules,
      -- Informational rules are inventory, not defects. An open TP-001
      -- ("these third-party scripts run on your site") must not drag a control
      -- to partial: nothing is wrong, it is a list.
      count(*) filter (
        where f.status in ('open','reopened') and f.severity in ('critical','high')
      ) as open_bad,
      count(*) filter (
        where f.status in ('open','reopened') and f.severity in ('medium','low')
      ) as open_soft
    from refs r
    left join muster.findings f
      on f.website_id = p_website_id
     and f.rule_id::text = any(r.rules)
    group by r.framework, r.reference, r.rules
  )
  insert into muster.controls
    (website_id, framework, reference, title, description, assessment, source)
  select
    p_website_id,
    s.framework,
    s.reference,
    replace(s.framework, '_', ' ') || ' ' || s.reference,
    format(
      '%s MUSTER check%s map to this reference: %s. Assessment reflects only what MUSTER assesses from the public web surface and is not a full control assessment.',
      array_length(s.rules, 1),
      case when array_length(s.rules, 1) = 1 then '' else 's' end,
      array_to_string(s.rules, ', ')),
    case
      when v_scans = 0 then 'not_assessed'
      when s.open_bad > 0 then 'not_met'
      when s.open_soft > 0 then 'partial'
      else 'met'
    end,
    'derived'
  from scored s
  on conflict (website_id, framework, reference) do update
    set title = case when muster.controls.source = 'derived' then excluded.title else muster.controls.title end,
        description = case when muster.controls.source = 'derived' then excluded.description else muster.controls.description end,
        assessment = case when muster.controls.source = 'derived' then excluded.assessment else muster.controls.assessment end,
        updated_at = case when muster.controls.source = 'derived' then now() else muster.controls.updated_at end;

  get diagnostics v_written = row_count;
  return v_written;
end;
$function$;

revoke all on function muster.sync_controls(bigint) from public;
revoke all on function muster.rule_control_refs() from public;

do $$
declare
  v_refs integer;
  v_manual integer;
begin
  select count(*) into v_refs from muster.rule_control_refs();
  if v_refs < 34 then
    raise exception 'expected at least 34 rule-to-reference mappings, found %', v_refs;
  end if;

  -- No CUSTOM row may still be carrying a WCAG criterion after normalization.
  if exists (select 1 from muster.rule_control_refs() where framework = 'CUSTOM' and reference like 'WCAG%') then
    raise exception 'a WCAG criterion is still classified CUSTOM';
  end if;

  -- Compound references must have been split, or the register gets a row whose
  -- reference is two references.
  if exists (select 1 from muster.rule_control_refs() where reference like '%,%') then
    raise exception 'a compound reference survived the split';
  end if;

  -- Every framework produced must satisfy the table's own CHECK, or the first
  -- sync fails at insert time instead of here.
  if exists (
    select 1 from muster.rule_control_refs()
    where framework not in ('SOC_2','ISO_27001','GDPR','PCI_DSS','WCAG','NIST_CSF','HIPAA','CUSTOM')
  ) then
    raise exception 'rule_control_refs produced a framework the controls CHECK rejects';
  end if;

  select count(*) into v_manual from muster.controls where source = 'manual';
  if v_manual <> 2 then
    raise exception 'expected the 2 pre-existing rows to be preserved as manual, found %', v_manual;
  end if;
end $$;
