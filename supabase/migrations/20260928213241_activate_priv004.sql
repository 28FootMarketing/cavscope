-- Releases the hold migration 20260928170144 put on PRIV-004 (no Terms of
-- Service link found). The gate was "engine http-native-1.11.0 or later
-- observed in production"; production has served 1.11.0 through 1.14.0
-- since deploy-functions run 36477693191 (merge of PR #158).
--
-- Proof, observed rather than assumed, by skipped_inactive arithmetic on
-- CavScope's own marketing site (website 23, cavscope.28footsystems.com):
--   scan 129, 1.10.0: skipped 4 = GOV-006 + GOV-007 + two older held rules.
--   GOV-006..008 were then activated (20260928164840).
--   scan 143, 1.11.0: skipped 3, not the 2 that activation alone predicts.
--   PRIV-004 is the only rule 1.11.0 added inactive, so the extra held
--   finding is PRIV-004: the engine emitted it and ingest refused it.
--   scans 157, 171, 185 (1.12.0..1.14.0) hold at 3, consistent.
-- The finding is legitimate: index.html carries no link whose text or href
-- contains "terms" or "tos" (the site's Terms of Service are pending
-- publication, per app.html).
--
-- Activating makes CavScope report a real low finding against its own
-- marketing site the next time it is scanned. That is the correct outcome
-- and is stated here plainly rather than discovered later.

update cavscope.scan_rules
   set active = true, updated_at = now()
 where rule_id = 'PRIV-004';

do $$
declare v_n integer; v_missing text;
begin
  select count(*) into v_n from cavscope.scan_rules where rule_id = 'PRIV-004' and active;
  if v_n <> 1 then
    raise exception 'expected PRIV-004 active, found %', v_n;
  end if;

  select string_agg(distinct r.framework, ', ') into v_missing
  from cavscope.rule_control_refs() r
  left join cavscope.frameworks f on f.key = r.framework
  where f.key is null;
  if v_missing is not null then
    raise exception 'frameworks missing from cavscope.frameworks: %', v_missing;
  end if;
end $$;
