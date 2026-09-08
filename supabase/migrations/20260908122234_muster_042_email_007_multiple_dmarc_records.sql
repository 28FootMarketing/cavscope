-- muster_042: EMAIL-007 (multiple DMARC records), and EMAIL-003 raised to high.
--
-- Found by running the rules against muster.partners after its own EMAIL-*
-- findings were meant to be fixed. The intended fix was to edit the existing
-- p=none record; what actually happened was a second record added beside it:
--
--   _dmarc.muster.partners  TXT  "v=DMARC1; p=none;"
--   _dmarc.muster.partners  TXT  "v=DMARC1; p=reject; rua=...; fo=1;"
--
-- RFC 7489 section 6.6.3: a name carrying more than one DMARC record is treated
-- as having no DMARC policy at all. Neither record applies. The domain went
-- from weakly protected to unprotected while looking, to the operator, like it
-- had just been hardened.
--
-- muster_040 had no rule for this, and worse, the evaluator read the first
-- record returned and judged the domain on it. Resolver ordering is not
-- stable, so the same domain could scan as "DMARC is monitoring only" or as
-- fully clean, run to run. The clean result is the dangerous one: it tells a
-- customer they are protected while every receiver ignores their policy.
-- EMAIL-007 is therefore checked before any policy is read.
--
-- EMAIL-003 (multiple SPF records) is the identical failure one protocol over,
-- and muster_040 shipped it at medium while EMAIL-001 (no SPF) was high. That
-- was wrong: RFC 7208 makes multiple records a permerror, so the exposure is
-- the same as publishing nothing. Severity tracks what an attacker can do, not
-- how close the operator came to getting it right. Raised to high here.

insert into muster.scan_rules
  (rule_id, category, title, description, default_severity, check_type, framework_refs, remediation, plain_english, active)
values
  ('EMAIL-007', 'security', 'Multiple DMARC records',
   'More than one v=DMARC1 TXT record is published at the same _dmarc name. RFC 7489 section 6.6.3 requires receivers to treat the domain as having no DMARC record at all.',
   'high', 'http_native',
   '{"NIST_CSF": "PR.DS-2", "CUSTOM": "RFC 7489 s6.6.3"}'::jsonb,
   'Delete every DMARC record at the name except the one you intend to publish. This is usually the result of adding a new record instead of editing the existing one; edit in place next time.',
   'You have two DMARC records, so receiving servers ignore both and treat your domain as having no policy. This is worse than the single weak record you replaced.',
   true)

on conflict (rule_id) do update set
  category = excluded.category, title = excluded.title, description = excluded.description,
  default_severity = excluded.default_severity, check_type = excluded.check_type,
  framework_refs = excluded.framework_refs, remediation = excluded.remediation,
  plain_english = excluded.plain_english, active = excluded.active;

update muster.scan_rules
   set default_severity = 'high',
       plain_english = 'You have two SPF records, so receiving servers ignore both. Your domain is as spoofable as if you published none.'
 where rule_id = 'EMAIL-003';

do $$
declare
  v_n integer;
begin
  select count(*) into v_n from muster.scan_rules where rule_id like 'EMAIL-%';
  if v_n <> 7 then
    raise exception 'expected 7 EMAIL-* rules, found %', v_n;
  end if;

  select count(*) into v_n from muster.scan_rules
   where rule_id like 'EMAIL-%' and category <> 'security';
  if v_n <> 0 then
    raise exception '% EMAIL-* rules are outside the security category', v_n;
  end if;

  -- The four rules that mean "this domain is spoofable right now" must all
  -- carry the same weight. Drifting them apart is what this migration fixes.
  select count(*) into v_n from muster.scan_rules
   where rule_id in ('EMAIL-001', 'EMAIL-003', 'EMAIL-004', 'EMAIL-007')
     and default_severity = 'high';
  if v_n <> 4 then
    raise exception 'the four no-effective-protection rules are not all high (% of 4)', v_n;
  end if;

  select count(*) into v_n from muster.scan_rules
   where rule_id like 'EMAIL-%' and not active;
  if v_n <> 0 then
    raise exception '% EMAIL-* rules are inactive', v_n;
  end if;
end $$;
