-- Flag registry text: say CavScope, and stop saying something false.
--
-- Two corrections, data only, no behaviour change.
--
-- 1. Five rows still named the product by its retired name in prose that a super
--    admin reads in the console: the display name of hide_attribution ("Hide
--    MUSTER attribution"), and descriptions or surfaces on accessibility_audit,
--    commercial_use_enabled, email_alerts and white_label_enabled. hide_attribution
--    described a line reading "Prepared by MUSTER"; reports have said "Prepared by
--    CavScope" since the rebrand, so that text was wrong as well as stale. Only the
--    uppercase word is replaced. Lowercase identifiers inside these texts
--    (public.muster_admin_run_url, muster-agent, muster_engine_claim_alerts) name
--    live objects and stay until docs/RENAME-PLAN.md retires them.
--
-- 2. client_management_enabled's wiring_note said the client-org creation path
--    "does not check" the flag. Read from the live catalog on 2026-10-01: no
--    function sets organizations.managed_by_org_id, so there is no creation path
--    to check it. The note now says what is true.
--
-- Nothing here touches enforcement. The block at the end aborts the migration if
-- any flag's enforcement array, or the number of flags, differs from before.

do $m$
declare
  v_before text;
  v_after text;
  v_count_before integer;
  v_count_after integer;
  v_left integer;
begin
  select md5(string_agg(key || ':' || coalesce(enforcement::text, ''), ',' order by key)), count(*)
    into v_before, v_count_before
  from cavscope.feature_flags;

  update cavscope.feature_flags
  set name = replace(name, 'MUSTER', 'CavScope'),
      description = replace(description, 'MUSTER', 'CavScope'),
      surface = replace(surface, 'MUSTER', 'CavScope'),
      wiring_note = replace(wiring_note, 'MUSTER', 'CavScope')
  where name ~ 'MUSTER' or description ~ 'MUSTER' or surface ~ 'MUSTER' or wiring_note ~ 'MUSTER';

  update cavscope.feature_flags
  set wiring_note = 'Sold on the Partner tier, but the capability does not exist: no function creates a client organization linked to a Partner account (organizations.managed_by_org_id is set by nothing), so there is no guard to add. The workspace''s "create client organization" button makes an independent trial organization. Build the creation path with a has_flag guard, then set enforcement in the same migration.'
  where key = 'client_management_enabled';

  select md5(string_agg(key || ':' || coalesce(enforcement::text, ''), ',' order by key)), count(*)
    into v_after, v_count_after
  from cavscope.feature_flags;

  if v_before is distinct from v_after then
    raise exception 'enforcement changed; this migration must not touch it';
  end if;
  if v_count_before is distinct from v_count_after then
    raise exception 'flag count changed: % -> %', v_count_before, v_count_after;
  end if;

  select count(*) into v_left from cavscope.feature_flags
  where name ~ 'MUSTER' or description ~ 'MUSTER' or surface ~ 'MUSTER' or wiring_note ~ 'MUSTER';
  if v_left <> 0 then
    raise exception '% flag rows still carry the uppercase retired name', v_left;
  end if;
end
$m$;
