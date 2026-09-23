-- MUSTER 086: SEC-016..020 and AUTH-006, six rules closing gaps identified in
-- a 2026-09-23 review of docs/SCAN-RULES.md against what the catalog does not
-- check yet. All six inserted INACTIVE. This migration does not deploy any
-- engine code -- see "INACTIVE ON PURPOSE" below before activating.
--
-- WHY THESE SIX
--
-- SEC-016 (sensitive file/path exposure), SEC-017 (CORS reflecting an
-- untrusted origin with credentials), SEC-018 (a CSP present but permissive
-- enough to defeat itself) and SEC-019 (TRACE/TRACK enabled) all read from
-- machinery the engine already has -- a plain GET, the header set it already
-- parses for SEC-004/SEC-011, the admin-probe pattern AUTH-004/005 already
-- use. AUTH-006 (login page not marked no-store) extends the login family's
-- own "worse than the homepage" discipline. SEC-020 (no DNSSEC delegation)
-- extends the DNS-over-HTTPS resolver the EMAIL-* family and SEC-015 already
-- call, the same way SEC-015 (CAA) did.
--
-- Deliberately NOT included here, and why, so the omission is not mistaken
-- for an oversight later:
--
-- - CVE / outdated-software version matching (WordPress core, plugins, JS
--   libraries). That is a vulnerability database MUSTER would have to build
--   and maintain, a different product shape from a citation-backed posture
--   scan, and it fails in the direction this project treats as worst: a
--   stale version list either misses a real defect or flags a patched one as
--   open, and either way the finding text asserts something the engine did
--   not verify.
-- - Open-redirect probing by guessing query parameter names (?next=,
--   ?redirect=). Against an unknown application shape in a single
--   unauthenticated GET, the false-positive and false-negative rate is high
--   enough that a finding would not be actionable -- the same reasoning that
--   keeps rate-limit probing and the autocomplete finding out of AUTH-*.
-- - Subdomain takeover / dangling CNAME and TLS certificate expiry /
--   protocol downgrade both remain real candidates, but neither is "one more
--   rule" on existing machinery: takeover detection needs a subdomain list
--   the engine does not have today (certificate-transparency lookup is a new
--   external data source), and certificate introspection needs a raw TLS
--   handshake the engine's fetch()-based transport does not perform. Both
--   need their own scoped build, not a stub alongside these six.
--
-- SEVERITY
--
-- SEC-016 high: a leaked .git tree or .env file is a direct path to
--   credentials, the same order of consequence as AUTH-005's exposed
--   database console.
-- SEC-017 high: an exact reflection of an untrusted Origin combined with
--   Access-Control-Allow-Credentials: true lets any attacker-controlled page
--   read authenticated responses from a signed-in visitor's browser.
-- SEC-018 medium: same weight as SEC-004, which it refines -- a CSP present
--   but permissive is a lesser defect than no CSP at all, not a different
--   one.
-- SEC-019 low: TRACE/TRACK requires a second vulnerability (an XSS
--   elsewhere on the origin) to be exploitable on its own account.
-- AUTH-006 medium: same weight as AUTH-002/AUTH-003, which it joins.
-- SEC-020 low: matches SEC-015 (CAA) -- a hardening gap almost no small
--   operator has closed, not an active compromise.
--
-- INACTIVE ON PURPOSE
--
-- None of the six is emitted by supabase/functions/muster-scan/index.ts yet.
-- Only SEC-016, SEC-017, SEC-018 and SEC-019 have module stubs at all
-- (exposure.ts, cors.ts, csp.ts, methods.ts) and none of the four is wired
-- into the fetch sequence, so today's engine (http-native-1.7.1) cannot
-- raise any of them. Per the same rule SEC-014/SEC-015/EMAIL-008 and
-- AUTH-001..005 were held to: a rule table row with no code path behind it
-- is worse than no row, because muster.rule_control_refs() would project it
-- into the control register and muster.sync_controls() would score an
-- untested reference as met the moment a site had a clean scan -- a
-- fabricated pass, not a gap.
--
-- Before activating any of these:
--   1. Wire the corresponding module into index.ts's fetch sequence, add
--      request/evidence handling, and confirm the four pure modules'
--      eventual unit tests pass.
--   2. Bump ENGINE_VERSION past the http-native-1.7.1 in index.ts today --
--      READ THE CURRENT VALUE ON MAIN FIRST, not the value this migration
--      was written against, per CLAUDE.md's own warning about exactly this
--      mistake. http-native-1.8.0 is a placeholder floor, not a promise.
--   3. Deploy via .github/workflows/deploy-functions.yml and observe a real
--      scan reporting that version or later in muster.scans.engine_version.
--   4. Only then, in a separate migration:
--        update muster.scan_rules set active = true, updated_at = now()
--         where rule_id in ('SEC-016','SEC-017','SEC-018','SEC-019',
--                            'AUTH-006','SEC-020');
--      and confirm the six begin appearing (or that skipped_inactive moves)
--      before telling anyone the coverage exists.
--
-- AUTH-006 and SEC-020 have no module stub in this pass. AUTH-006 extends
-- login.ts's evaluateLoginPage with a Cache-Control check against the same
-- HomepageBaseline shape; SEC-020 extends hardening.ts with a DNSKEY/DS walk
-- alongside evaluateCaa. Writing the row now, inactive, is the same
-- discipline as writing AUTH-* and SEC-014/015 before their engines shipped:
-- the row documents the gap without claiming to close it.

insert into muster.scan_rules (
  rule_id, category, title, description, default_severity, check_type,
  framework_refs, remediation, plain_english, active
) values
(
  'SEC-016', 'security',
  'Sensitive file or directory exposed',
  'A GET to a small set of default paths for source-control metadata, environment files, and database backups (.git/config, .git/HEAD, .env, .DS_Store, common SQL dump names) returns content matching that file type''s own signature, not merely a 200 status. Confirmed on content the same way AUTH-004/AUTH-005 confirm an admin console, so a single-page app that answers every path with 200 is never accused of leaking its .git directory.',
  'high', 'http_native',
  '{"SOC_2":"CC6.1","NIST_CSF_V2":"PR.PS-01","NIST_800_53":"AC-3, CM-6","OWASP_TOP10":"A01:2025, A02:2025"}'::jsonb,
  'Remove the file from the web root or block it at the web server/CDN (deny .git, .env, .DS_Store and *.sql, *.bak by path). If a .git directory was exposed, treat every credential ever committed to that repository as compromised and rotate it -- this scan confirms exposure, not that cloning the tree was the only thing anyone did with it.',
  'A file on your server that should never be public -- source control history, a settings file with passwords in it, or a database backup -- answers when requested directly. Anyone who finds the address can read it.',
  false
),
(
  'SEC-017', 'security',
  'CORS misconfiguration allows credentialed cross-origin reads',
  'A request carrying an Origin the server has no reason to trust is echoed back verbatim in Access-Control-Allow-Origin alongside Access-Control-Allow-Credentials: true. That combination lets a page on any attacker-controlled domain make an authenticated, cookie-carrying request to this site and read the response inside a signed-in visitor''s browser. A wildcard or reflected Access-Control-Allow-Origin without credentials is not flagged: browsers refuse that combination outright, and reporting it would be the same error EMAIL-002 avoids by leaving ~all alone.',
  'high', 'http_native',
  '{"SOC_2":"CC6.1","NIST_CSF_V2":"PR.PS-01","NIST_800_53":"AC-4","OWASP_TOP10":"A01:2025, A02:2025"}'::jsonb,
  'Return Access-Control-Allow-Origin only for an explicit, maintained allowlist of origins that legitimately need credentialed cross-origin access -- never by reflecting whatever Origin arrived. If nothing needs credentialed cross-origin access, drop Access-Control-Allow-Credentials entirely.',
  'Your site will hand information meant only for signed-in visitors to a request coming from any other website, as long as that visitor is already signed in here. A page anywhere on the internet can use this to read data that should be private to your users.',
  false
),
(
  'SEC-018', 'security',
  'Content-Security-Policy allows unsafe inline or eval scripts',
  'A Content-Security-Policy is present -- SEC-004 owns its absence -- but its effective script directive (script-src, or default-src when script-src is not set) permits unsafe-inline, unsafe-eval, or an unrestricted wildcard source, or neither directive restricts scripts at all. Each of those defeats the one thing a CSP exists to stop: an attacker''s injected script executing.',
  'medium', 'http_native',
  '{"SOC_2":"CC6.6","NIST_CSF_V2":"PR.PS-01","NIST_800_53":"CM-6","OWASP_TOP10":"A02:2025"}'::jsonb,
  'Move inline scripts to external files and drop unsafe-inline; where inline script cannot be avoided yet, use a per-response nonce or hash instead of the keyword. Remove unsafe-eval and refactor code that depends on eval or new Function. Replace a wildcard script-src with the specific hosts the site actually loads scripts from.',
  'Your site has a policy meant to stop injected malicious scripts from running, but the policy itself still allows the two things that make injection dangerous: scripts written inline on the page, or scripts built from text at runtime. It is a lock with the key left in it.',
  false
),
(
  'SEC-019', 'security',
  'TRACE/TRACK HTTP method enabled',
  'The web server accepts an HTTP TRACE request and echoes it back in the response body. Combined with a cross-site scripting flaw elsewhere on the same origin, TRACE can be used to read headers -- including a cookie marked HttpOnly -- that script cannot otherwise reach (Cross-Site Tracing). It requires a second vulnerability to matter, which is why this is rated low rather than reported as exploitable on its own.',
  'low', 'http_native',
  '{"NIST_CSF_V2":"PR.PS-01","NIST_800_53":"CM-7","OWASP_TOP10":"A02:2025"}'::jsonb,
  'Disable the TRACE and TRACK methods at the web server or load balancer. Nearly every server ships a documented directive for this (Apache TraceEnable off, an IIS URL-rewrite rule, or a reverse proxy that strips the verb before it reaches the origin).',
  'Your server responds to an unusual, rarely-needed type of request by echoing it back, which can be combined with an unrelated bug elsewhere to read cookies that are supposed to be off-limits to scripts. Turning this off costs the site nothing.',
  false
),
(
  'AUTH-006', 'security',
  'Login page response is cacheable',
  'A login page''s response carries no Cache-Control: no-store (or an equivalent directive that prevents caching), so a shared or intermediary cache -- a corporate proxy, a CDN caching by default, or a browser''s disk cache on a shared computer -- may retain a copy of it. Raised only on the login page itself, matching the rest of the AUTH family''s "worse than the homepage" discipline: an ordinary marketing page is meant to be cached, and PRIV-003 and SEC-011 already own what the homepage does with forms and cookies.',
  'medium', 'http_native',
  '{"SOC_2":"CC6.1","NIST_CSF_V2":"PR.DS-01","NIST_800_53":"SC-28","OWASP_TOP10":"A02:2025, A07:2025"}'::jsonb,
  'Send Cache-Control: no-store, no-cache, must-revalidate and Pragma: no-cache on the login page and on every response that can carry session state (post-login redirects, password reset, account pages). A static, cacheable login page shell is fine -- it is the response headers caching respects, not the visible content.',
  'Your sign-in page does not tell browsers and shared caches not to store a copy of it, so on a shared or public computer, the previous visitor''s sign-in page can be pulled back up from the cache.',
  false
),
(
  'SEC-020', 'security',
  'DNSSEC not enabled',
  'The domain publishes no DS record delegating a DNSSEC chain of trust from its parent zone, or no DNSKEY at the domain itself, so a resolver has no cryptographic way to detect a forged DNS answer for this domain. A resolver failure is never treated as absence of DNSSEC, matching the discipline the EMAIL family already applies: an outage reports nothing rather than manufacturing a finding.',
  'low', 'http_native',
  '{"NIST_CSF":"PR.DS-2","NIST_CSF_V2":"PR.DS-02","NIST_800_53":"SC-20, SC-21","CUSTOM":"RFC 4033"}'::jsonb,
  'Enable DNSSEC signing with your DNS host or registrar and confirm the resulting DS record is published at the registrar, not only the DNSKEY at the zone -- a signed zone with no DS record at the parent is signed and unverifiable at the same time, which is the most common way this is half-done.',
  'Your domain name has no cryptographic signature protecting it, so a resolver has no way to tell a forged answer from a real one. DNSSEC is the one control that closes that gap; almost no small-business domain has it, so this is a differentiator, not an emergency.',
  false
)
on conflict (rule_id) do nothing;

-- Every framework these rules cite must already be in the lookup, or
-- sync_controls fails at insert the way it did on 2026-09-16. All six above
-- use only keys muster_059 already seeded, but this stays as a live check
-- rather than an assumption, matching muster_061's own discipline.
do $$
declare v_missing text;
begin
  select string_agg(distinct r.framework, ', ') into v_missing
  from muster.rule_control_refs() r
  left join muster.frameworks f on f.key = r.framework
  where f.key is null;
  if v_missing is not null then
    raise exception 'new rules reference frameworks missing from muster.frameworks: %', v_missing;
  end if;
end $$;

-- Assertions: all six exist, all six are inactive with the stated
-- severities, all are category security / check_type http_native, and
-- nothing else in the catalog moved.
do $$
declare
  v_n int;
  v_inactive int;
  v_total int;
  v_refs int;
begin
  select count(*) into v_n from muster.scan_rules
   where (rule_id, default_severity) in (
     ('SEC-016','high'), ('SEC-017','high'), ('SEC-018','medium'),
     ('SEC-019','low'), ('AUTH-006','medium'), ('SEC-020','low'))
     and not active and category = 'security' and check_type = 'http_native';
  if v_n <> 6 then
    raise exception 'expected 6 inactive rules with the stated severities, found %', v_n;
  end if;

  select count(*), count(*) filter (where not active) into v_total, v_inactive
    from muster.scan_rules;
  if v_inactive <> 6 then
    raise exception 'expected exactly 6 inactive rules (SEC-016..020, AUTH-006), found %', v_inactive;
  end if;

  -- The point of inserting inactive: none of the six may reach the control
  -- register until the engine that emits it is deployed and observed.
  select count(*) into v_refs from muster.rule_control_refs()
   where rule_id in ('SEC-016','SEC-017','SEC-018','SEC-019','AUTH-006','SEC-020');
  if v_refs <> 0 then
    raise exception 'held rules are already projected into the control register (% refs)', v_refs;
  end if;

  raise notice 'SEC-016..020 and AUTH-006 added inactive; % rules total', v_total;
end $$;
