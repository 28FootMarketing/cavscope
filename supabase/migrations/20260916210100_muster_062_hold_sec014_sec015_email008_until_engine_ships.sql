-- Holds SEC-014, SEC-015 and EMAIL-008 inactive until the scan engine that
-- emits them is deployed. muster_061 inserted them active, which was wrong in
-- exactly the way CLAUDE.md already warns about for feature flags: never declare
-- a thing enabled before the code reading it exists.
--
-- The specific hazard here is not a missing finding, it is a false clean.
-- muster.rule_control_refs() projects every ACTIVE rule into the control
-- register, and muster.sync_controls() scores a reference 'met' when the website
-- has completed scans and no open findings map to it. A rule the engine never
-- evaluates has no findings by construction, so it would have rendered as a met
-- control -- reporting that a site was checked for Subresource Integrity and
-- passed, when it was never checked at all. On a compliance product that is the
-- worst failure available: not a gap, a fabricated assurance.
--
-- Deactivating removes them from rule_control_refs() entirely, so the register
-- neither claims nor denies anything about them.
--
-- TO ACTIVATE, once muster-scan is running engine version http-native-1.2.0
-- (check muster.scans.engine_version on a scan newer than the deploy):
--
--   update muster.scan_rules set active = true, updated_at = now()
--    where rule_id in ('SEC-014','SEC-015','EMAIL-008');
--
-- then re-run a scan and confirm the three appear before telling anyone the
-- coverage exists.

update muster.scan_rules
   set active = false, updated_at = now()
 where rule_id in ('SEC-014', 'SEC-015', 'EMAIL-008');

do $$
declare v_active integer; v_refs integer;
begin
  select count(*) into v_active from muster.scan_rules
   where rule_id in ('SEC-014','SEC-015','EMAIL-008') and active;
  if v_active <> 0 then
    raise exception 'expected the three held rules to be inactive, % are active', v_active;
  end if;

  -- The point of the hold: they must not reach the control register.
  select count(*) into v_refs from muster.rule_control_refs()
   where rule_id in ('SEC-014','SEC-015','EMAIL-008');
  if v_refs <> 0 then
    raise exception 'held rules are still projected into the control register (% refs)', v_refs;
  end if;
end $$;