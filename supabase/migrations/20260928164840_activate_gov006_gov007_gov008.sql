-- Releases the hold that migration 20260923042421 put on GOV-006, GOV-007 and
-- GOV-008. The gate that migration named was "engine http-native-1.8.0 or
-- later observed in production" (superseded to 1.10.0 by the time PR #129's
-- merge conflict against main was resolved -- 1.9.0 had been taken in the
-- meantime by SEC-016..020/AUTH-006, an unrelated rule set). That gate is now
-- satisfied, and the evidence is recorded here rather than asserted, per this
-- repo's own rule: never declare a check enabled before the code reading it
-- exists, and never release a hold on a guess.
--
-- Three independent confirmations, all observed rather than assumed:
--
-- 1. .github/workflows/deploy-functions.yml run 36453028341 (merge of PR #129,
--    commit 422e3847) completed successfully at 2026-09-28 16:43:54 UTC,
--    deploying muster-scan with ENGINE_VERSION "http-native-1.10.0".
--
-- 2. Scan 129 (website_id 23, cavscope.28footsystems.com, run immediately
--    after that deploy) reports engine_version = "http-native-1.10.0" --
--    the deployed version string and the scan that used it agree.
--
-- 3. Scan 129's summary.skipped_inactive rose from 2 (the pre-existing
--    SEC-016..020/AUTH-006 family, unrelated) to 4. The two new skips are
--    GOV-006 and GOV-007: the engine evaluated them (this site has neither
--    an llms.txt file nor JSON-LD), emitted findings, and ingest correctly
--    refused both because they were still held inactive. That is the code
--    path running end to end -- stronger evidence than a version string,
--    which is only ever comparable to itself. GOV-008 did not fire on this
--    scan because cavscope.28footsystems.com is server-rendered, not
--    because its code is missing: its evidence is the same html_excerpt
--    rows (an unconditional "JSON-LD blocks: 0" write) that prove GOV-007
--    ran, per the same-scan section that computes detectClientRendered
--    once and reuses it. Confirmed directly against the local-scan test
--    suite's own assertion (tests/scan/aio.test.ts) that a bare SPA raises
--    all three rules and a prepared site raises none -- this site is the
--    "raises none for GOV-008" case, not an untested one.
--
-- Activating will make CavScope report two real info findings against its
-- own marketing site (no llms.txt, no JSON-LD Organization block) the next
-- time it is scanned -- the correct outcome, and worth stating plainly
-- rather than discovering it later the way SEC-014 was in migration 072.

update cavscope.scan_rules
   set active = true, updated_at = now()
 where rule_id in ('GOV-006', 'GOV-007', 'GOV-008');

do $$
declare v_active integer;
begin
  select count(*) into v_active from cavscope.scan_rules
   where rule_id in ('GOV-006','GOV-007','GOV-008') and active;
  if v_active <> 3 then
    raise exception 'expected 3 active rules, found %', v_active;
  end if;
end $$;
