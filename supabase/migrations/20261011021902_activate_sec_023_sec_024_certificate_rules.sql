-- Releases the hold migration 20261011013757 put on SEC-023 (certificate expired)
-- and SEC-024 (certificate expires within 14 days). The gate was "a deployed scan
-- shows the raw TLS read works". Observed 2026-10-11 after PR #234 deployed
-- cavscope-scan http-native-1.16.0:
--   scans 290..309 (every registered website, 19 of 20 complete at the time of
--   reading): every completed scan wrote a tls_certificate evidence row with
--   state 'ok' (16 of 16), days_remaining 37 to 181, 0 unavailable.
-- No website is inside the 14-day window, so activation opens no finding today.
-- It will the first time a certificate gets within 14 days, which is the point.

update cavscope.scan_rules
   set active = true, updated_at = now()
 where rule_id in ('SEC-023', 'SEC-024');

do $$
declare v_n integer; v_missing text;
begin
  select count(*) into v_n from cavscope.scan_rules
   where rule_id in ('SEC-023', 'SEC-024') and active;
  if v_n <> 2 then
    raise exception 'expected SEC-023 and SEC-024 active, found %', v_n;
  end if;

  select string_agg(distinct r.framework, ', ') into v_missing
  from cavscope.rule_control_refs() r
  left join cavscope.frameworks f on f.key = r.framework
  where f.key is null;
  if v_missing is not null then
    raise exception 'frameworks missing from cavscope.frameworks: %', v_missing;
  end if;
end $$;
