-- The control register has been failing to rebuild since 2026-09-16 19:23 UTC.
--
-- muster.controls.framework is varchar(16) with a hardcoded CHECK listing eight
-- values. The AI-governance rules added that day introduced
-- 'california_ai_transparency_act' (30 characters), so muster.sync_controls()
-- threw 22001 on insert. muster_045 deliberately swallows that failure into an
-- activity_events row rather than failing the scan, which is the right call and
-- is also why nobody saw it: one real scan at 19:30:04 recorded
-- "Control register refresh failed / value too long for type character
-- varying(16)" and the register silently stopped tracking findings.
--
-- Widening the column alone would fix today and break again on the next
-- framework, because the actual defect is that the set of valid frameworks lived
-- in DDL. Adding a scan rule is a data change; it should never require altering
-- a constraint, and when it does, the failure lands far away from the edit.
--
-- So the set becomes a table. muster.frameworks holds the key and its display
-- label, controls.framework references it, and muster.framework_label() reads
-- from it. Adding a framework is now one insert, and an unknown framework fails
-- loudly at the assertion at the bottom of this migration instead of quietly at
-- runtime a week later.

create table if not exists muster.frameworks (
  key         varchar(64) primary key,
  label       varchar(120) not null,
  sort_order  integer not null default 100,
  created_at  timestamptz not null default now()
);

comment on table muster.frameworks is
  'Every framework a scan rule may reference. controls.framework is FK to this, and framework_label() reads it. Adding a framework is an insert here, not a constraint edit.';

insert into muster.frameworks (key, label, sort_order) values
  ('NIST_CSF_V2',                    'NIST CSF 2.0',            10),
  ('NIST_CSF',                       'NIST CSF 1.1',            20),
  ('NIST_800_53',                    'NIST SP 800-53 Rev. 5',   30),
  ('OWASP_TOP10',                    'OWASP Top 10:2025',       40),
  ('OWASP_SECURE_HEADERS',           'OWASP Secure Headers',    50),
  ('SOC_2',                          'SOC 2 (AICPA TSC)',       60),
  ('ISO_27001',                      'ISO/IEC 27001',           70),
  ('PCI_DSS',                        'PCI DSS',                 80),
  ('GDPR',                           'GDPR',                    90),
  ('WCAG',                           'WCAG',                   100),
  ('HIPAA',                          'HIPAA',                  110),
  ('california_ai_transparency_act', 'California AI Transparency Act', 120),
  ('colorado_admt_act',              'Colorado AI Act (ADMT)', 130),
  ('colorado_chatbot_act',           'Colorado Chatbot Act',   140),
  ('CUSTOM',                         'Reference',              999)
on conflict (key) do update set label = excluded.label, sort_order = excluded.sort_order;

alter table muster.controls alter column framework type varchar(64);
alter table muster.controls drop constraint if exists controls_framework_check;

-- Any framework already in controls that is somehow not in the lookup would
-- block the FK. There should be none; this makes that explicit rather than
-- letting ALTER fail with a less readable message.
do $$
declare v_orphans text;
begin
  select string_agg(distinct c.framework, ', ') into v_orphans
  from muster.controls c
  left join muster.frameworks f on f.key = c.framework
  where f.key is null;
  if v_orphans is not null then
    raise exception 'controls rows reference unknown frameworks: %', v_orphans;
  end if;
end $$;

alter table muster.controls
  add constraint controls_framework_fkey
  foreign key (framework) references muster.frameworks(key);

-- Reads the table now, so it is stable rather than immutable.
create or replace function muster.framework_label(p_framework text)
returns text language sql stable set search_path to '' as $$
  select coalesce(
    (select f.label from muster.frameworks f where f.key = p_framework),
    replace(p_framework, '_', ' ')
  );
$$;

-- Patch the title expression in sync_controls by rewriting the live definition
-- rather than restating the whole function, which is muster_045's principle:
-- a restatement can silently revert an unrelated change someone else made.
do $$
declare
  v_def text;
  v_old text := 'replace(s.framework, ''_'', '' '') || '' '' || s.reference';
  v_new text := 'muster.framework_label(s.framework) || '' '' || s.reference';
begin
  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'muster' and p.proname = 'sync_controls';

  if v_def is null then
    raise exception 'muster.sync_controls not found';
  end if;
  if position(v_old in v_def) = 0 then
    raise exception 'title expression anchor not found in sync_controls; it has changed shape';
  end if;

  execute replace(v_def, v_old, v_new);

  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'muster' and p.proname = 'sync_controls';
  if position(v_new in v_def) = 0 then
    raise exception 'sync_controls was not patched';
  end if;
end $$;

revoke all on function muster.framework_label(text) from public;

-- The guard that makes this permanent: every framework any active rule
-- references must exist in the lookup. A new rule with a typo or a new framework
-- fails here, at migration time, with the offending key named.
do $$
declare v_missing text;
begin
  select string_agg(distinct r.framework, ', ') into v_missing
  from muster.rule_control_refs() r
  left join muster.frameworks f on f.key = r.framework
  where f.key is null;
  if v_missing is not null then
    raise exception 'scan rules reference frameworks missing from muster.frameworks: %', v_missing;
  end if;
end $$;

-- Rebuild every website's register, which has been stale since 19:23.
do $$
declare v_id bigint; v_total integer := 0; v_n integer;
begin
  for v_id in select id from muster.websites loop
    select muster.sync_controls(v_id) into v_n;
    v_total := v_total + coalesce(v_n, 0);
  end loop;
  raise notice 'control register rebuilt: % rows across all websites', v_total;
end $$;