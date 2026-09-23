-- MUSTER 081: activate AUTH-003, and correct its description.
--
-- 20260923012945 (muster_080) activated AUTH-001, 002, 004 and 005 and held
-- AUTH-003, because its first live firing was false in substance: scan 86 on
-- www.hanoverymca.org reported wordpress_test_cookie, which WordPress sets to
-- the constant "WP Cookie check" to test cookie support and which never becomes
-- a session. Engine http-native-1.7.1 (#122) skips it by exact name. The gate
-- was "a scan reports 1.7.1 or later". Satisfied, and the evidence is the same
-- site before and after:
--
-- 1. Deployed from CI: deploy-functions run 35806705653 on the merge of #122
--    (33c6d1f), success.
--
-- 2. Scan 89, engine 1.7.0, www.hanoverymca.org: skipped_inactive = 1. That
--    one was AUTH-003 on wordpress_test_cookie; AUTH-004, already active, was
--    ingested at low.
--
-- 3. Scan 90, engine 1.7.1, same site, minutes later: the login page's evidence
--    still shows wordpress_test_cookie being set, and skipped_inactive = 0. The
--    cookie is unchanged; the engine stopped reporting it. That is the fix
--    observed in production rather than only in tests.
--
-- 4. Scan 91, engine 1.7.1, berecruitabledaily.com: its /auth login page was
--    assessed and sets no cookies, and catch-all 200s on all five admin paths
--    again matched nothing.
--
-- Not yet observed live: AUTH-003 firing on a real session cookie. The loud
-- path is covered in tests (tests/scan/login.test.ts), including a real
-- wordpress_logged_in_* cookie and a lookalike name beside the exempted one.
--
-- The description is rewritten because muster_079's text claimed a pre-login
-- cookie "commonly becomes the signed-in session", which is exactly the
-- overstatement the first firing exposed. The engine's finding text was
-- corrected in 1.7.1; this brings the catalogue row into line with it.

update muster.scan_rules
   set description = 'Before anyone signs in, a login page sets a cookie missing Secure, HttpOnly or SameSite. A session cookie issued before sign-in is often the one that carries the signed-in session afterwards, unless the application issues a new one at sign-in. Cookies already reported on the homepage by SEC-011 are excluded; anti-forgery tokens (names containing csrf or xsrf) are not asked for HttpOnly because frameworks expose them to script on purpose; and cookies that carry no identity by design, such as wordpress_test_cookie, are not reported.',
       active = true,
       updated_at = now()
 where rule_id = 'AUTH-003';

do $$
declare
  v_active boolean;
  v_desc text;
  v_inactive int;
  v_missing text;
begin
  select active, description into v_active, v_desc from muster.scan_rules where rule_id = 'AUTH-003';
  if not coalesce(v_active, false) then
    raise exception 'AUTH-003 did not activate';
  end if;
  if v_desc ilike '%commonly becomes%' then
    raise exception 'AUTH-003 still carries the corrected claim';
  end if;
  if v_desc not ilike '%wordpress_test_cookie%' then
    raise exception 'AUTH-003 description does not name the exemption';
  end if;

  if not exists (select 1 from muster.rule_control_refs() where rule_id = 'AUTH-003') then
    raise exception 'AUTH-003 is active but projects no control refs';
  end if;

  select string_agg(distinct c.framework, ', ') into v_missing
    from muster.rule_control_refs() c
    left join muster.frameworks f on f.key = c.framework
   where f.key is null;
  if v_missing is not null then
    raise exception 'frameworks missing from muster.frameworks: %', v_missing;
  end if;

  -- The whole AUTH family is now live, and nothing else is held.
  select count(*) into v_inactive from muster.scan_rules where not active;
  if v_inactive <> 0 then
    raise exception 'expected no inactive rules, found %', v_inactive;
  end if;
end $$;
