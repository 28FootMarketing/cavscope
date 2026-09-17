-- muster_066: activate AVAIL-003, now that the engine emitting it is deployed.
--
-- The precondition from muster_065's header is met: muster-scan is deployed at
-- http-native-1.4.0, which carries the 401/403/429 split. Until this statement
-- the rule existed and was inactive, so migration 20260917061404's ingest guard
-- dropped its findings on arrival -- which is the correct order and the reason
-- the guard exists.
--
-- Deliberately a separate migration from 065 rather than a flag flipped in it.
-- The standing rule is that a rule waits for its engine, and "added inactive,
-- deployed, then activated" is three observable states; collapsing them into one
-- migration would make the wait unverifiable and would have activated the rule
-- while the deployed engine still could not emit it.

update muster.scan_rules
   set active = true, updated_at = now()
 where rule_id = 'AVAIL-003';
