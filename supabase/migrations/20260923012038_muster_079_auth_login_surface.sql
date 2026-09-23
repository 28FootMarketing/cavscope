-- MUSTER 079: AUTH-001..005, the login surface, read from outside.
--
-- WHY
--
-- The engine has only ever read the homepage. A login page is the one page
-- every attacker is guaranteed to reach, and it is often served by different
-- software from the homepage -- a portal, a CMS admin, a vendor module -- with
-- its own headers and cookies. MUSTER does not sign in and must not: holding
-- client credentials would make it a target, and testing behind a login is
-- penetration testing, which needs a signed scope. But the login page itself
-- is public by definition, so what it reveals before anyone types into it is
-- fair to read.
--
-- WHAT THE ENGINE DOES (http-native-1.7.0, supabase/functions/muster-scan/login.ts)
--
-- Plain GETs only, nothing submitted, no credential sent. It follows up to three
-- same-site "Sign in" links from the homepage and requests five default admin
-- paths. A page counts as a login page only if its served HTML contains a
-- password field; an admin path counts only on that product's own form
-- signature, never on a status code, because a single-page app answers every
-- path with 200. Off-site login links (a vendor's portal) are recorded in
-- evidence and never judged, because they are not the client's system.
--
-- ONE DEFECT, ONE FINDING
--
-- AUTH-001..003 fire only where the login page is WORSE than the homepage. An
-- HTTP-only site is SEC-013's at critical; no framing header anywhere is
-- SEC-005's; a cookie the homepage already set badly is SEC-011's. Scoring
-- those again per login page found would move posture by how many pages the
-- engine happened to discover rather than by how many things are wrong.
--
-- SEVERITY
--
-- AUTH-001 high: a password in plaintext on a site that is otherwise HTTPS.
-- AUTH-005 high: a database console on the open internet is one password from
--   the whole dataset.
-- AUTH-002, AUTH-003 medium: same weights as SEC-005 and SEC-011, which they
--   refine.
-- AUTH-004 low: a CMS login at its default path is normal for that CMS and not
--   a vulnerability on its own. It is reported because it is where password
--   guessing is aimed, and its text says MFA and rate limiting are unseen
--   rather than absent -- the engine never signs in, so it cannot know.
--
-- What was deliberately left out: rate-limit or lockout probing (that is trying
-- passwords against real users), and an "autocomplete allowed" finding (NIST SP
-- 800-63B and OWASP ASVS now say password managers should be allowed, so that
-- finding would be advice to make the site worse).
--
-- INACTIVE ON PURPOSE
--
-- A rule waits for the engine that emits it. Since 20260917061404,
-- muster.engine_ingest drops findings whose rule is inactive and reports the
-- count as skipped_inactive. Engine floor is http-native-1.7.0 -- a floor, not
-- an equality. Activate in a separate migration once a 1.7.0-or-later scan is
-- observed. The proof of deploy is the evidence row keyed login_discovery,
-- written on every reachable scan whether or not a login page exists: these
-- rules are silent on most sites, so skipped_inactive may legitimately stay 0.

insert into muster.scan_rules (
  rule_id, category, title, description, default_severity, check_type,
  framework_refs, remediation, plain_english, active
) values
(
  'AUTH-001', 'security',
  'Login credentials can travel unencrypted',
  'A login page reached from the homepage or a default admin path either is served over plain HTTP on a site whose homepage is HTTPS, or contains a password form whose action submits to plain HTTP. The password leaves the browser unencrypted. Raised only where the login page is worse than the homepage; an HTTP-only site is SEC-013.',
  'high', 'http_native',
  '{"SOC_2":"CC6.1, CC6.7","PCI_DSS":"4.2.1, 8.3.2","NIST_CSF":"PR.DS-2","NIST_800_53":"SC-8, IA-5(1)","NIST_CSF_V2":"PR.DS-02","OWASP_TOP10":"A04:2025, A07:2025"}'::jsonb,
  'Serve the login page only over HTTPS and redirect its HTTP address to HTTPS. Make every password form post to an https:// action. Check the software that serves the login separately from the homepage: portals and admin modules often have their own configuration.',
  'Your sign-in page sends passwords without encryption, even though the rest of your site is encrypted. Anyone on the same network, such as public Wi-Fi, can read them.'
  , false
),
(
  'AUTH-002', 'security',
  'Login page can be framed by another site',
  'The homepage sends X-Frame-Options or a CSP frame-ancestors directive, but a login page does not. Another site can load the login form inside an invisible frame and trick a visitor into typing into it or clicking through it. Raised only where the homepage is protected; a site with no framing protection anywhere is SEC-005.',
  'medium', 'http_native',
  '{"SOC_2":"CC6.6","NIST_CSF":"PR.PT-3","NIST_800_53":"SC-18","NIST_CSF_V2":"PR.PS-01","OWASP_TOP10":"A02:2025, A07:2025","OWASP_SECURE_HEADERS":"X-Frame-Options"}'::jsonb,
  'Send Content-Security-Policy: frame-ancestors ''self'' (or X-Frame-Options: SAMEORIGIN) from the login page. If the homepage already sends it, the login is served by a different application or route that does not inherit the setting.',
  'Your sign-in page can be hidden inside another website, which can trick people into entering their password where an attacker can see it. Your homepage is protected against this; the sign-in page is not.'
  , false
),
(
  'AUTH-003', 'security',
  'Login page sets cookies without protective flags',
  'Before anyone signs in, a login page sets a cookie missing Secure, HttpOnly or SameSite. A cookie set here commonly becomes the signed-in session. Cookies already reported on the homepage by SEC-011 are excluded, and anti-forgery tokens (names containing csrf or xsrf) are not asked for HttpOnly because frameworks expose them to script on purpose.',
  'medium', 'http_native',
  '{"SOC_2":"CC6.1, CC6.7","NIST_CSF":"PR.DS-1","NIST_800_53":"SC-23","NIST_CSF_V2":"PR.DS-01","OWASP_TOP10":"A02:2025, A07:2025","OWASP_SECURE_HEADERS":"Set-Cookie"}'::jsonb,
  'Set Secure; HttpOnly; SameSite=Lax (or Strict) on the session and authentication cookies the login page issues, and issue a new session identifier after a successful sign-in.',
  'The cookie your sign-in page uses to remember visitors is missing basic protections, so it could be stolen or reused to take over an account.'
  , false
),
(
  'AUTH-004', 'security',
  'CMS administrator login is reachable at its default path',
  'The administrator login of a known CMS (WordPress, Joomla or Drupal) answers at its default path, confirmed by the product''s own login form rather than a status code. Normal for that CMS and not a vulnerability on its own; it is where automated password guessing is aimed. MUSTER does not sign in, so it cannot see whether multi-factor authentication or login rate limiting is enforced.',
  'low', 'http_native',
  '{"SOC_2":"CC6.1","NIST_CSF":"PR.AC-7","NIST_800_53":"AC-7, IA-2(1)","NIST_CSF_V2":"PR.AA-03","OWASP_TOP10":"A07:2025"}'::jsonb,
  'Require multi-factor authentication for every administrator account and enable login rate limiting or lockout. Where administrators work from known networks, restrict the admin path by IP or put it behind a VPN or identity-aware proxy. Renaming the path is not a control on its own.',
  'Your website''s admin sign-in page is at the standard address, where automated password-guessing attacks look first. Make sure admin accounts use two-step sign-in.'
  , false
),
(
  'AUTH-005', 'security',
  'Database administration console is publicly reachable',
  'A database administration console (phpMyAdmin or Adminer) answers at its default path to anyone on the internet, confirmed by the product''s own login form rather than a status code. It is a direct login to the database behind the site.',
  'high', 'http_native',
  '{"SOC_2":"CC6.1, CC6.6","NIST_CSF":"PR.AC-3","NIST_800_53":"AC-17, SC-7","NIST_CSF_V2":"PR.IR-01","OWASP_TOP10":"A02:2025, A07:2025"}'::jsonb,
  'Remove the console from the public web server. If it is needed, restrict it to an allowlist of IP addresses or a VPN, require strong unique credentials, and keep it patched. Rotate the database passwords if the console has been exposed for any length of time.',
  'A tool that gives direct access to your website''s database can be reached by anyone on the internet. One guessed or leaked password would expose all of the data behind your site.'
  , false
)
on conflict (rule_id) do nothing;

-- Assertions: all five exist, all five are inactive, severities are as stated,
-- and nothing else moved.
do $$
declare
  v_n int;
  v_inactive int;
  v_total int;
begin
  select count(*) into v_n from muster.scan_rules
   where (rule_id, default_severity) in (
     ('AUTH-001','high'), ('AUTH-002','medium'), ('AUTH-003','medium'),
     ('AUTH-004','low'), ('AUTH-005','high'))
     and not active and category = 'security' and check_type = 'http_native';
  if v_n <> 5 then
    raise exception 'expected 5 inactive AUTH-* rules with the stated severities, found %', v_n;
  end if;

  select count(*), count(*) filter (where not active) into v_total, v_inactive
    from muster.scan_rules;
  if v_inactive <> 5 then
    raise exception 'expected exactly 5 inactive rules (AUTH-001..005), found %', v_inactive;
  end if;
  raise notice 'AUTH-001..005 added inactive; % rules total', v_total;
end $$;
