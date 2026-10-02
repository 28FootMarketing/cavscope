-- Activate SEC-016..SEC-020 and AUTH-006, the step 4 that migration 20260925051249
-- left for after the engine shipped. Engine http-native-1.15.0 is deployed and wires all
-- six (index.ts); every scan since 2026-10-01 reports skipped_inactive > 0, and a local
-- scan of cavscope.28footsystems.com raised AUTH-006, SEC-018 and SEC-020 on 2026-10-02.
-- Goes through scan_rule_set_active so the change lands in the rule history.
do $$
declare r text;
begin
  foreach r in array array['AUTH-006','SEC-016','SEC-017','SEC-018','SEC-019','SEC-020'] loop
    perform cavscope.scan_rule_set_active(r, true,
      'Engine wires the rule and is deployed; owner instruction 2026-10-02', 'http-native-1.15.0',
      '20260925051249 step 4');
  end loop;
  if (select count(*) from cavscope.scan_rules
       where rule_id in ('AUTH-006','SEC-016','SEC-017','SEC-018','SEC-019','SEC-020') and active) <> 6 then
    raise exception 'expected all six rules active';
  end if;
end $$;
