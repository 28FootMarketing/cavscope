-- The 20260925 audit-log migrations (this session's own work) were originally
-- drafted as muster_088/090 and stored those provisional names as
-- scan_rule_history.migration_ref -- SEC-019's retirement, and the three
-- ai_governance deactivation backfill rows. Recovering 13 more migrations
-- applied with no file (2026-09-23's beta-signups batch) forced those files
-- to renumber up to 099/102 to keep sequence numbers rising with version (the
-- same reason 083/084/085 were renumbered earlier this session). The stored
-- migration_ref text is data whose whole purpose is pointing at a real file;
-- unlike the frozen SQL bytes those files carry (which must stay byte-
-- identical to what the ledger recorded), this is this session's own
-- just-written data, not deep history, so it is corrected in place rather
-- than left stale.

update muster.scan_rule_history
   set migration_ref = '20260923210000_muster_102_scan_rule_lifecycle_audit'
 where migration_ref = '20260923210000_muster_088_scan_rule_lifecycle_audit';

update muster.scan_rule_history
   set migration_ref = '20260925005911_muster_099_deactivate_unbuilt_ai_governance_checks'
 where migration_ref = '20260925005911_muster_090_deactivate_unbuilt_ai_governance_checks';

do $$
declare v_stale int;
begin
  select count(*) into v_stale from muster.scan_rule_history
   where migration_ref in (
     '20260923210000_muster_088_scan_rule_lifecycle_audit',
     '20260925005911_muster_090_deactivate_unbuilt_ai_governance_checks'
   );
  if v_stale <> 0 then
    raise exception 'expected 0 rows with the stale pre-renumbering migration_ref, found %', v_stale;
  end if;
end $$;
