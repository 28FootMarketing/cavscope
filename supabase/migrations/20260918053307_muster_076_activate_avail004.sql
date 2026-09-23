-- MUSTER 076: activate AVAIL-004.
--
-- Added inactive by 20260917174318 pending the engine that emits it. That engine
-- is now deployed and observed, and this migration records the evidence rather
-- than asserting it.
--
-- PROOF THE DEPLOY LANDED
--
-- Scan 63 against https://hpsd.k12.pa.us/ (website 13), run minutes after the
-- merge of #120 and the first genuine CI deploy this project has had:
--
--   engine_version   http-native-1.6.0
--   skipped_inactive 1
--
-- Both halves matter. The version string alone is only ever compared to itself,
-- so it proves nothing on its own -- that is the lesson of 20260916210100, whose
-- named version was superseded twice and never deployed. `skipped_inactive: 1`
-- is the load-bearing number: the engine emitted a finding whose rule_id is
-- AVAIL-004 and muster.engine_ingest refused it, which cannot happen unless the
-- deployed code contains the rule. The gate and the deploy are proven by the
-- same observation.
--
-- The same scan resolved the AVAIL-001 this rule exists to replace (`resolved:
-- 1`) and the site's score moved 53 -> 78, red -> amber, because the false
-- critical is gone. That 78 is still not an assessment of the site: the engine
-- read no markup, headers or cookies, which is precisely what AVAIL-004 is for
-- saying out loud. Activating it puts the honest critical back in place of the
-- dishonest one -- the score will return to the low 50s and it will mean
-- something different, which is the entire point of the change.
--
-- WHAT ACTIVATION DOES
--
-- Findings are gated on active, evidence is not, so nothing collected between
-- 20260917174318 and now is lost. Reactivation is reversible: deactivate and the
-- open findings retire; reactivate, rescan, and they reopen against the same
-- fingerprint.

update muster.scan_rules
   set active = true, updated_at = now()
 where rule_id = 'AVAIL-004' and not active;

do $$
declare
  v_active boolean;
  v_inactive int;
  v_total int;
  v_engine text;
  v_skipped int;
begin
  select active into v_active from muster.scan_rules where rule_id = 'AVAIL-004';
  if v_active is not true then
    raise exception 'AVAIL-004 is not active after the update';
  end if;

  -- The engine that emits it must have been observed, not assumed. A floor, not
  -- an equality: any version at or past 1.6.0 carries the rule.
  select engine_version, (summary->>'skipped_inactive')::int
    into v_engine, v_skipped
    from muster.scans
   where id = 63;
  if v_engine is null then
    raise exception 'scan 63 not found; the observation this migration rests on is missing';
  end if;
  if v_engine < 'http-native-1.6.0' then
    raise exception 'scan 63 ran on %, which is behind the floor http-native-1.6.0', v_engine;
  end if;
  if coalesce(v_skipped, 0) < 1 then
    raise exception 'scan 63 reported skipped_inactive=%, so the deployed engine never emitted the held rule', v_skipped;
  end if;

  select count(*), count(*) filter (where not active) into v_total, v_inactive
    from muster.scan_rules;
  if v_inactive <> 0 then
    raise exception 'expected no inactive rules after activation, found %', v_inactive;
  end if;
  raise notice 'AVAIL-004 active; % rules, all active; observed % with skipped_inactive=%', v_total, v_engine, v_skipped;
end $$;
