-- EMAIL-009: SPF exceeds the DNS lookup limit.
--
-- RFC 7208 4.6.4 caps SPF evaluation at 10 DNS-querying terms (include, a, mx,
-- ptr, exists, and the redirect modifier). Past that a receiver returns
-- permerror, which most treat exactly as they treat no SPF at all -- so the
-- domain publishes a long, careful, correct-looking record that protects
-- nothing.
--
-- High, not medium, for the same reason EMAIL-003 is high: the exposure is
-- identical to publishing no SPF (EMAIL-001, high). Severity tracks what an
-- attacker can do, not how close the operator came to getting it right.
--
-- Why this rule earns its place: it is the most common way SPF fails in
-- practice and the least visible one. The count is not in the record. A domain
-- can list three vendors and be over the limit because one of them nests four
-- includes of its own, and nothing bounces, nothing reports, and no dashboard
-- anywhere shows it. It is also pure DNS -- no browser, no authenticated crawl,
-- no permission from the target -- so it works on exactly the sites where the
-- HTTP half of the engine gets refused.
--
-- INACTIVE ON PURPOSE. Production serves http-native-1.4.0; this rule is
-- emitted by 1.5.0. An active rule the engine never evaluates has no findings
-- by construction, and sync_controls() scores a reference with no open findings
-- as MET -- so activating early would report a check that never ran as passed.
-- muster.engine_ingest also drops findings whose rule is inactive and counts
-- them as skipped_inactive, so the wait is enforced rather than decorative.
--
-- TO ACTIVATE, after confirming a real scan reports engine http-native-1.5.0
-- OR LATER (a floor, not an equality -- 20260916210100 named 1.2.0, which was
-- superseded twice and never deployed):
--
--   update muster.scan_rules set active = true, updated_at = now()
--    where rule_id = 'EMAIL-009';

insert into muster.scan_rules
  (rule_id, category, default_severity, check_type, title, description,
   plain_english, remediation, framework_refs, active)
values (
  'EMAIL-009',
  'security',
  'high',
  'http_native',
  'SPF exceeds the DNS lookup limit',
  'Evaluating the SPF record requires more than the 10 DNS-querying terms RFC 7208 section 4.6.4 '
    || 'allows, counted across the whole include tree. Receivers return permerror, which is commonly '
    || 'treated as no SPF at all.',
  'Your SPF record is correct but too long to be used. Checking it takes more DNS lookups than the '
    || 'standard allows, so receiving mail servers give up partway through and treat your domain as if it '
    || 'had no SPF record at all. Nothing bounces and nothing warns you; the protection is simply not '
    || 'applied. This usually happens as vendors accumulate, because each one you include can bring '
    || 'several of its own.',
  'Count the DNS-querying terms across the whole record, including everything your includes pull in: '
    || 'include, a, mx, ptr, exists and redirect each cost one, and the limit is 10 for the entire tree. '
    || 'Remove senders you no longer use, replace an include with the specific ip4/ip6 ranges it resolves '
    || 'to where the vendor publishes stable addresses, or consolidate vendors. Re-check after every '
    || 'change: this fails silently, so the only confirmation is counting again.',
  jsonb_build_object(
    'CUSTOM', 'RFC 7208 4.6.4',
    'NIST_CSF', 'PR.DS-2',
    'NIST_CSF_V2', 'PR.DS-02',
    'NIST_800_53', 'SC-8',
    'SOC_2', 'CC6.7'
  ),
  false
);

do $$
declare v_active boolean; v_sev text; v_refs integer;
begin
  select active, default_severity into v_active, v_sev
    from muster.scan_rules where rule_id = 'EMAIL-009';
  if v_active is null then raise exception 'EMAIL-009 was not inserted'; end if;
  if v_active then raise exception 'EMAIL-009 must ship inactive; the engine emitting it is not deployed'; end if;
  if v_sev <> 'high' then raise exception 'expected high, got %', v_sev; end if;

  -- An inactive rule must NOT reach the control register. This is the property
  -- the hold exists to protect, so it is asserted rather than assumed.
  select count(*) into v_refs from muster.rule_control_refs() where rule_id = 'EMAIL-009';
  if v_refs <> 0 then
    raise exception 'EMAIL-009 is inactive but projects % control refs', v_refs;
  end if;

  -- Every framework it cites must exist, or sync_controls throws 22001 on
  -- insert the way it did on 2026-09-16 and the register goes silently stale.
  if exists (
    select 1 from jsonb_object_keys(
      (select framework_refs from muster.scan_rules where rule_id = 'EMAIL-009')) k
    left join muster.frameworks f on f.key = k
    where f.key is null
  ) then
    raise exception 'EMAIL-009 cites a framework missing from muster.frameworks';
  end if;
end $$;
