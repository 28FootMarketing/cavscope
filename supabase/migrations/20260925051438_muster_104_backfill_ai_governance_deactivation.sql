-- Completes the 089 backfill: migration 20260925005911
-- (deactivate_unbuilt_ai_governance_checks) ran before 088 added
-- scan_rule_history, so its deactivation of the three ai_governance rules
-- with no working check (ai-chatbot-present-undisclosed,
-- ai-vendor-undisclosed, ai-generated-content-undisclosed) was never
-- captured by the trigger. 089's backfill only recorded their original
-- 'created' (active=true) row, which left the audit log silently missing
-- the one transition that actually matters for these three -- the same
-- "invisible to the audit trail" failure this whole audit log exists to
-- prevent going forward. Inserted directly with the real historical
-- timestamp (090's own updated_at), matching 089's own convention for
-- historical rows.

insert into muster.scan_rule_history (rule_id, action, previous_active, new_active, reason, migration_ref, created_at)
select rule_id, 'deactivated', true, false,
       'No working check in this HTTP-native-only engine: check_type ''browser'' (ai-chatbot-present-undisclosed, ai-vendor-undisclosed) or ''manual'' (ai-generated-content-undisclosed). Had been scoring live tenant controls as met with no check ever run since creation on 2026-09-16. Deactivated on explicit authorization.',
       '20260925005911_muster_090_deactivate_unbuilt_ai_governance_checks',
       updated_at
  from muster.scan_rules
 where rule_id in ('ai-chatbot-present-undisclosed','ai-vendor-undisclosed','ai-generated-content-undisclosed');

do $$
declare v_n int;
begin
  select count(*) into v_n from muster.scan_rule_history
   where rule_id in ('ai-chatbot-present-undisclosed','ai-vendor-undisclosed','ai-generated-content-undisclosed')
     and action = 'deactivated';
  if v_n <> 3 then
    raise exception 'expected 3 deactivated rows for the ai_governance rules, found %', v_n;
  end if;
end $$;
