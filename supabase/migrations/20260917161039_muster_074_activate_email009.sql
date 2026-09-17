-- Activates EMAIL-009, released from the hold that 20260917150811 placed on it.
--
-- That migration's gate was "a real scan reports engine http-native-1.5.0 or
-- later". Satisfied, and the evidence is recorded here rather than asserted,
-- because the hold existed to stop a fabricated assurance and releasing it on a
-- guess would produce exactly that.
--
-- 1. Scan 55 (website 7, muster.partners, 2026-09-17) reported engine
--    http-native-1.5.0. The deploy came from CI -- run 35238552263, 52 seconds,
--    deploy step success -- not from a paste.
--
-- 2. The rule's code path is proven by its evidence row, not by the version
--    string. Scan 55 carried dns_spf_chain reading "0 of 10 DNS lookups /
--    walked: muster.partners". muster.partners publishes v=spf1 -all, which has
--    no DNS-querying terms, so zero is the correct count and the walk ran.
--
--    Note this is NOT the skipped_inactive proof used for SEC-014. Here the rule
--    correctly emitted nothing, so skipped_inactive stayed 0 and proves nothing
--    either way. The evidence row is what shows the path executed.
--
-- 3. Recursion verified against real nested records. Scan 56 (studyfetch.com)
--    reported "2 of 10 DNS lookups / walked: studyfetch.com -> _spf.google.com
--    -> 46924488.spf06.hubspotemail.net". Both includes were resolved and both
--    turned out to be flat: _spf.google.com is now entirely ip4/ip6 with no
--    nested includes, and so is HubSpot's. Both were read directly from
--    dns.google to confirm, because 2 looked low against a remembered version of
--    Google's record that no longer exists. The count was right; the memory was
--    not. Verifying is the reason a correct rule was not "fixed" into a wrong one.
--
-- What this rule does NOT yet have is a live firing observation. No domain
-- scanned so far exceeds 10, so the over-limit branch is covered by unit tests
-- only. That is a known gap, stated rather than papered over: the silent path
-- is proven live, the loud path is proven in tests.

update muster.scan_rules
   set active = true, updated_at = now()
 where rule_id = 'EMAIL-009';

do $$
declare v_active boolean; v_refs integer; v_missing text;
begin
  select active into v_active from muster.scan_rules where rule_id = 'EMAIL-009';
  if not coalesce(v_active, false) then raise exception 'EMAIL-009 did not activate'; end if;

  -- It must now reach the control register, which is the point of activating.
  select count(*) into v_refs from muster.rule_control_refs() where rule_id = 'EMAIL-009';
  if v_refs = 0 then
    raise exception 'EMAIL-009 is active but projects no control refs';
  end if;

  -- And every framework any active rule cites must exist, or sync_controls
  -- throws 22001 on insert and the register goes silently stale.
  select string_agg(distinct r.framework, ', ') into v_missing
  from muster.rule_control_refs() r
  left join muster.frameworks f on f.key = r.framework
  where f.key is null;
  if v_missing is not null then
    raise exception 'frameworks missing from muster.frameworks: %', v_missing;
  end if;
end $$;
