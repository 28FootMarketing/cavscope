-- Releases the hold that migration 20260916210100 put on SEC-014, SEC-015 and
-- EMAIL-008. The gate that migration named was "once muster-scan is running an
-- engine that carries these rules". That is now satisfied, and the evidence is
-- recorded here rather than asserted, because the hold existed to stop a
-- fabricated assurance and releasing it on a guess would produce exactly that.
--
-- Three independent confirmations, all observed rather than assumed:
--
-- 1. Production has served engine http-native-1.4.0 since 2026-09-17 07:17 UTC.
--    muster.scans shows the progression 1.1.1 -> 1.3.0 (06:56) -> 1.4.0 (07:17),
--    so the deploy that was blocked on the SUPABASE_ACCESS_TOKEN secret has since
--    happened.
--
-- 2. main's supabase/functions/muster-scan/index.ts is ENGINE_VERSION 1.4.0 and
--    wires all three evaluators from hardening.ts, so the deployed version string
--    and the source that carries the rules are the same release.
--
-- 3. Scan 51 (website 7, muster.partners, 2026-09-17 10:34) reported
--    summary.skipped_inactive = 1. The engine emitted a finding for a held rule
--    and ingest refused it. That is the code path running end to end -- stronger
--    evidence than a version string, which is only ever compared to itself.
--
-- The finding that was skipped is SEC-014 against MUSTER's own marketing site:
-- index.html loads @supabase/supabase-js from cdn.jsdelivr.net with crossorigin
-- but no integrity. Activating makes MUSTER report a real medium finding against
-- muster.partners, which is the correct outcome and worth stating plainly rather
-- than discovering later.
--
-- Note the remediation is not a one-liner there: the src pins a floating major
-- (@supabase/supabase-js@2), and a hash cannot be taken of a file that is meant
-- to change. Pinning an exact version comes first. SEC-014's remediation text
-- already says so.

update muster.scan_rules
   set active = true, updated_at = now()
 where rule_id in ('SEC-014', 'SEC-015', 'EMAIL-008');

do $$
declare v_active integer; v_refs integer; v_missing text;
begin
  select count(*) into v_active from muster.scan_rules
   where rule_id in ('SEC-014','SEC-015','EMAIL-008') and active;
  if v_active <> 3 then
    raise exception 'expected 3 active rules, found %', v_active;
  end if;

  -- They should now reach the control register, which is the whole point.
  select count(*) into v_refs from muster.rule_control_refs()
   where rule_id in ('SEC-014','SEC-015','EMAIL-008');
  if v_refs = 0 then
    raise exception 'activated rules are not projected into the control register';
  end if;

  -- Every framework they cite must exist, or sync_controls throws on insert the
  -- way it did on 2026-09-16.
  select string_agg(distinct r.framework, ', ') into v_missing
  from muster.rule_control_refs() r
  left join muster.frameworks f on f.key = r.framework
  where f.key is null;
  if v_missing is not null then
    raise exception 'frameworks missing from muster.frameworks: %', v_missing;
  end if;
end $$;