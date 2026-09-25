-- MUSTER 090: deactivate the three ai_governance rules that have no engine
-- behind them, at the owner's explicit direction.
--
-- `ai-chatbot-present-undisclosed` and `ai-vendor-undisclosed` are
-- check_type 'browser'; `ai-generated-content-undisclosed` is 'manual'. This
-- engine is HTTP-native only -- there is no browser step (the accessibility
-- view's own "Browser engine" pillar scores 0/10 and is not checked) and no
-- manual-review workflow anywhere in the product. All three have been
-- `active` since 2026-09-16 (migration 20260916192324, itself applied with
-- no file in this repo until a scan-rule audit-log session recovered it on
-- 2026-09-23 -- see supabase/migrations/README.md), which means every scan
-- since has scored those three controls **met** by an absence of findings
-- the engine was never able to produce. Same failure `SEC-014`/`SEC-015`/
-- `EMAIL-008` were held inactive on 2026-09-16 to prevent (migration
-- 20260916210100), found live here for a different rule family a week later.
--
-- `ai-admt-policy-silent` and `ai-crawler-directives-missing` are untouched:
-- both are check_type 'http_native' and have a real code path in
-- supabase/functions/muster-scan/index.ts.
--
-- Deactivating drops all three out of muster.rule_control_refs() (it reads
-- `active`), so the control register stops claiming a check that was never
-- run, and it also retires any open findings against them per migration
-- 20260917061404's own rule -- reversible: reactivate once a browser engine
-- or manual-review workflow exists, and evidence already collected is not
-- lost.
--
-- Plain update, not muster.scan_rule_set_active(): that function and
-- muster.scan_rule_history do not exist on this project yet (drafted and
-- tested in supabase/migrations/088-089, not yet applied). This migration's
-- own prose is today's record of the change, the same way every migration
-- before 088 has been.

update muster.scan_rules
   set active = false, updated_at = now()
 where rule_id in ('ai-chatbot-present-undisclosed', 'ai-vendor-undisclosed', 'ai-generated-content-undisclosed');

do $$
declare
  v_inactive int;
  v_refs int;
  v_untouched_active int;
begin
  select count(*) into v_inactive from muster.scan_rules
   where rule_id in ('ai-chatbot-present-undisclosed', 'ai-vendor-undisclosed', 'ai-generated-content-undisclosed')
     and not active;
  if v_inactive <> 3 then
    raise exception 'expected all three to be inactive, found %', v_inactive;
  end if;

  -- The two rules with a real check path must not have been touched.
  select count(*) into v_untouched_active from muster.scan_rules
   where rule_id in ('ai-admt-policy-silent', 'ai-crawler-directives-missing') and active;
  if v_untouched_active <> 2 then
    raise exception 'ai-admt-policy-silent / ai-crawler-directives-missing must stay active, found % active', v_untouched_active;
  end if;

  -- The point of the deactivation: they must not reach the control register.
  select count(*) into v_refs from muster.rule_control_refs()
   where rule_id in ('ai-chatbot-present-undisclosed', 'ai-vendor-undisclosed', 'ai-generated-content-undisclosed');
  if v_refs <> 0 then
    raise exception 'deactivated rules are still projected into the control register (% refs)', v_refs;
  end if;

  raise notice 'ai-chatbot-present-undisclosed, ai-vendor-undisclosed, ai-generated-content-undisclosed deactivated; control register no longer claims them';
end $$;
