-- MUSTER 080: activate AUTH-001, AUTH-002, AUTH-004 and AUTH-005. AUTH-003 stays held.
--
-- 20260923012038 (muster_079) added AUTH-001..005 inactive with the gate "a
-- scan reports http-native-1.7.0 or later". Satisfied, and recorded here
-- rather than asserted:
--
-- 1. Deployed from CI, not a paste: deploy-functions run 35806182345 on the
--    merge of #121 (914e8e4), token proven by read, deploy step 51 s, success.
--
-- 2. Six sandbox scans, 83..88, all report http-native-1.7.0 and all carry the
--    login_discovery evidence row, which the engine writes on every reachable
--    scan. That row is the proof the code path ran, since these rules are
--    silent on most sites.
--
-- 3. The loud path was observed live, not only in tests. Scan 86
--    (www.hanoverymca.org) reported skipped_inactive = 2: the engine emitted two
--    AUTH findings and ingest refused them. Its evidence identifies them:
--    AUTH-004 on /wp-login.php (matched WordPress by its own form), and AUTH-003
--    on /login/ for wordpress_test_cookie. AUTH-002 correctly stayed silent: the
--    homepage has no framing protection either, so SEC-005 owns it.
--
-- 4. The false-positive guards were observed live. thesavvypointe.com,
--    pathtoclarity.solutions and berecruitabledaily.com answer /phpmyadmin/,
--    /administrator/ and /user/login with HTTP 200 (catch-all routes) and none
--    matched, so no AUTH-005 was raised against a site that does not run
--    phpMyAdmin. hanoverboroughpa.gov's "My Account" links redirect to
--    cpauthentication.civicplus.com and were recorded as off-site, not judged.
--
-- WHY AUTH-003 IS NOT ACTIVATED
--
-- Its one live firing was wrong in substance. wordpress_test_cookie carries the
-- constant value "WP Cookie check"; WordPress sets it to learn whether the
-- browser accepts cookies, and it never becomes a session. The finding's text
-- says a cookie set there "commonly becomes the signed-in session", which is
-- false for it, and activating would put a medium finding on the login page of
-- every WordPress site for a cookie that carries nothing. The correction is an
-- engine change, so AUTH-003 waits for the release that carries it, under the
-- same floor-not-equality gate as before.
--
-- Not yet observed live: AUTH-001 and AUTH-005 firing. No sandbox site served
-- an HTTP login or a database console. Their silent paths are proven live and
-- their loud paths in tests, the same position EMAIL-009 was activated from.

update muster.scan_rules
   set active = true, updated_at = now()
 where rule_id in ('AUTH-001', 'AUTH-002', 'AUTH-004', 'AUTH-005');

do $$
declare
  v_active int;
  v_held boolean;
  v_unmapped text;
  v_missing text;
begin
  select count(*) into v_active from muster.scan_rules
   where rule_id in ('AUTH-001', 'AUTH-002', 'AUTH-004', 'AUTH-005') and active;
  if v_active <> 4 then
    raise exception 'expected 4 AUTH rules active, found %', v_active;
  end if;

  select active into v_held from muster.scan_rules where rule_id = 'AUTH-003';
  if v_held is distinct from false then
    raise exception 'AUTH-003 must stay inactive until the wordpress_test_cookie fix is deployed';
  end if;

  -- Each activated rule must now reach the control register, which is the
  -- point of activating.
  select string_agg(r.rule_id, ', ') into v_unmapped
    from unnest(array['AUTH-001', 'AUTH-002', 'AUTH-004', 'AUTH-005']) r(rule_id)
   where not exists (select 1 from muster.rule_control_refs() c where c.rule_id = r.rule_id);
  if v_unmapped is not null then
    raise exception 'active but projecting no control refs: %', v_unmapped;
  end if;

  -- Every framework an active rule cites must exist, or sync_controls throws
  -- and the register goes silently stale.
  select string_agg(distinct c.framework, ', ') into v_missing
    from muster.rule_control_refs() c
    left join muster.frameworks f on f.key = c.framework
   where f.key is null;
  if v_missing is not null then
    raise exception 'frameworks missing from muster.frameworks: %', v_missing;
  end if;
end $$;
