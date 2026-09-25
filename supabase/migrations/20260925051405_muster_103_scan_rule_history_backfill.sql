insert into muster.scan_rule_history (rule_id, action, previous_active, new_active, reason, engine_version, migration_ref, created_at) values
  ('SEC-014', 'created', null, true,
   'Subresource Integrity on third-party scripts; inserted active, which migration 062 immediately caught as premature.',
   null, '20260916205549_muster_061_sec014_sri_sec015_caa_email008_mtasts', '2026-09-16 20:55:49.033801+00'),
  ('SEC-014', 'deactivated', true, false,
   'A rule the engine never evaluates has no findings by construction, so rule_control_refs() would have scored it met -- a fabricated pass, not a gap. Held until http-native-1.2.0-or-later is observed.',
   null, '20260916210100_muster_062_hold_sec014_sec015_email008_until_engine_ships', '2026-09-16 21:01:00+00'),
  ('SEC-014', 'activated', false, true,
   'Engine http-native-1.3.0 (the floor moved past 1.2.0, which was superseded twice and never deployed) observed live; the rule now has code behind it.',
   'http-native-1.3.0', '20260917111614_muster_072_activate_sec014_sec015_email008', '2026-09-17 11:16:14.793181+00'),

  ('SEC-015', 'created', null, true,
   'No CAA record restricts certificate issuance; inserted active alongside SEC-014, same premature-activation mistake.',
   null, '20260916205549_muster_061_sec014_sri_sec015_caa_email008_mtasts', '2026-09-16 20:55:49.033801+00'),
  ('SEC-015', 'deactivated', true, false,
   'Held with SEC-014 and EMAIL-008 for the same reason: no engine code yet.',
   null, '20260916210100_muster_062_hold_sec014_sec015_email008_until_engine_ships', '2026-09-16 21:01:00+00'),
  ('SEC-015', 'activated', false, true,
   'Activated with SEC-014 once http-native-1.3.0 was observed live.',
   'http-native-1.3.0', '20260917111614_muster_072_activate_sec014_sec015_email008', '2026-09-17 11:16:14.793181+00'),

  ('EMAIL-008', 'created', null, true,
   'No MTA-STS policy; inserted active alongside SEC-014/015, same premature-activation mistake.',
   null, '20260916205549_muster_061_sec014_sri_sec015_caa_email008_mtasts', '2026-09-16 20:55:49.033801+00'),
  ('EMAIL-008', 'deactivated', true, false,
   'Held with SEC-014 and SEC-015 for the same reason: no engine code yet.',
   null, '20260916210100_muster_062_hold_sec014_sec015_email008_until_engine_ships', '2026-09-16 21:01:00+00'),
  ('EMAIL-008', 'activated', false, true,
   'Activated with SEC-014/015 once http-native-1.3.0 was observed live.',
   'http-native-1.3.0', '20260917111614_muster_072_activate_sec014_sec015_email008', '2026-09-17 11:16:14.793181+00'),

  ('AVAIL-003', 'created', null, false,
   'A homepage answering 401/403/429 is the scanner being refused, not an outage; added inactive pending the engine.',
   null, '20260917071020_muster_065_avail003_scanner_refused', '2026-09-17 07:10:20.15973+00'),
  ('AVAIL-003', 'activated', false, true,
   'Engine deployed and observed.', null,
   '20260917071751_muster_066_activate_avail003', '2026-09-17 07:17:51.691673+00'),

  ('AVAIL-004', 'created', null, false,
   'A response received and rejected during HTTP parsing is not an outage either; added inactive pending the engine.',
   null, '20260917174318_muster_075_avail004_unparsable_response', '2026-09-17 17:43:18.051585+00'),
  ('AVAIL-004', 'activated', false, true,
   'Scan 63 against hpsd.k12.pa.us reported engine http-native-1.6.0 and skipped_inactive: 1 -- the engine emitted the finding and ingest refused it, proving the deploy landed.',
   'http-native-1.6.0', '20260918053307_muster_076_activate_avail004', '2026-09-18 05:33:07.277093+00'),

  ('EMAIL-009', 'created', null, false,
   'Counts SPF''s DNS-querying terms against RFC 7208''s 10-lookup limit; added inactive pending the walking engine.',
   null, '20260917150811_muster_073_email009_spf_lookup_limit', '2026-09-17 15:08:11.749715+00'),
  ('EMAIL-009', 'activated', false, true,
   'dns_spf_chain evidence row observed on a live scan, proving the walk executed.',
   null, '20260917161039_muster_074_activate_email009', '2026-09-17 16:10:39.000162+00'),

  ('AUTH-001', 'created', null, false,
   'Login page serving credentials over plain HTTP; added inactive with the rest of the login-surface family.',
   null, '20260923012038_muster_079_auth_login_surface', '2026-09-23 01:20:38.119628+00'),
  ('AUTH-001', 'activated', false, true,
   'Engine http-native-1.7.0 observed live via the login_discovery evidence row.',
   'http-native-1.7.0', '20260923012945_muster_080_activate_auth', '2026-09-23 01:29:45.40475+00'),

  ('AUTH-002', 'created', null, false,
   'Login page framable where the homepage is not; added inactive with the login-surface family.',
   null, '20260923012038_muster_079_auth_login_surface', '2026-09-23 01:20:38.119628+00'),
  ('AUTH-002', 'activated', false, true,
   'Activated with AUTH-001/004/005.', 'http-native-1.7.0',
   '20260923012945_muster_080_activate_auth', '2026-09-23 01:29:45.40475+00'),

  ('AUTH-003', 'created', null, false,
   'Login page cookies without protective flags; added inactive with the login-surface family.',
   null, '20260923012038_muster_079_auth_login_surface', '2026-09-23 01:20:38.119628+00'),
  ('AUTH-003', 'activated', false, true,
   'Held one release longer than AUTH-001/002/004/005: its first live firing was wordpress_test_cookie, a constant value that never becomes a session. Engine 1.7.1 stopped reporting it by exact name, and scan 90 on the same site showed the real cookie still correctly reported -- activated once that was confirmed.',
   'http-native-1.7.1', '20260923013901_muster_081_activate_auth003', '2026-09-23 01:39:01.572807+00'),

  ('AUTH-004', 'created', null, false,
   'CMS administrator login reachable at its default path; added inactive with the login-surface family.',
   null, '20260923012038_muster_079_auth_login_surface', '2026-09-23 01:20:38.119628+00'),
  ('AUTH-004', 'activated', false, true,
   'Activated with AUTH-001/002/005.', 'http-native-1.7.0',
   '20260923012945_muster_080_activate_auth', '2026-09-23 01:29:45.40475+00'),

  ('AUTH-005', 'created', null, false,
   'Database administration console publicly reachable; added inactive with the login-surface family.',
   null, '20260923012038_muster_079_auth_login_surface', '2026-09-23 01:20:38.119628+00'),
  ('AUTH-005', 'activated', false, true,
   'Activated with AUTH-001/002/004.', 'http-native-1.7.0',
   '20260923012945_muster_080_activate_auth', '2026-09-23 01:29:45.40475+00')
;

insert into muster.scan_rule_history (rule_id, action, previous_active, new_active, reason, migration_ref, created_at) values
  ('GOV-006', 'created', null, false,
   'No llms.txt file; AIO-readiness rule, inactive with no engine code yet.',
   '20260923042421_muster_083_gov006_008_aio_readiness', '2026-09-23 04:24:21.739381+00'),
  ('GOV-007', 'created', null, false,
   'No readable structured data (JSON-LD); AIO-readiness rule, inactive with no engine code yet.',
   '20260923042421_muster_083_gov006_008_aio_readiness', '2026-09-23 04:24:21.739381+00'),
  ('GOV-008', 'created', null, false,
   'Homepage content rendered by script, not served; AIO-readiness rule, inactive with no engine code yet.',
   '20260923042421_muster_083_gov006_008_aio_readiness', '2026-09-23 04:24:21.739381+00'),

  ('ai-admt-policy-silent', 'created', null, true,
   'Automated decision-making used without policy disclosure. check_type http_native -- this one has a real code path.',
   '20260916192324_add_ai_governance_scan_rules', '2026-09-16 19:23:24.700048+00'),
  ('ai-crawler-directives-missing', 'created', null, true,
   'No AI-crawler policy in robots.txt/llms.txt. check_type http_native -- this one has a real code path.',
   '20260916192324_add_ai_governance_scan_rules', '2026-09-16 19:23:24.700048+00'),
  ('ai-chatbot-present-undisclosed', 'created', null, true,
   'Conversational AI present without disclosure. Inserted active with check_type ''browser'' -- this HTTP-native engine has no browser step (docs/SCAN-RULES.md: "0/10 and is not checked"), so this has been scoring met with no check ever run since creation.',
   '20260916192324_add_ai_governance_scan_rules', '2026-09-16 19:23:24.700048+00'),
  ('ai-vendor-undisclosed', 'created', null, true,
   'Third-party AI vendor undisclosed. Inserted active with check_type ''browser'' -- same unrun-check condition as ai-chatbot-present-undisclosed.',
   '20260916192324_add_ai_governance_scan_rules', '2026-09-16 19:23:24.700048+00'),
  ('ai-generated-content-undisclosed', 'created', null, true,
   'AI-generated content shown without disclosure. Inserted active with check_type ''manual'' -- no automated path exists for this engine to ever emit it.',
   '20260916192324_add_ai_governance_scan_rules', '2026-09-16 19:23:24.700048+00')
;

insert into muster.scan_rule_history (rule_id, action, previous_active, new_active, reason, created_at)
select rule_id, 'created', null, active,
       '(bulk-copied baseline catalog; created_at is preserved from the old shared project, not this one, and not a reconstruction. See supabase/migrations/README.md.)',
       created_at
  from muster.scan_rules
 where created_at = timestamptz '2026-09-04 03:49:22.608386+00';

insert into muster.scan_rule_history (rule_id, action, previous_active, new_active, reason, created_at)
select rule_id, 'created', null, active,
       '(created via its own migration; never changed since, so this is the only history row it has.)',
       created_at
  from muster.scan_rules
 where created_at <> timestamptz '2026-09-04 03:49:22.608386+00'
   and rule_id not in (
     'SEC-014','SEC-015','EMAIL-008','AVAIL-003','AVAIL-004','EMAIL-009',
     'AUTH-001','AUTH-002','AUTH-003','AUTH-004','AUTH-005',
     'GOV-006','GOV-007','GOV-008',
     'ai-admt-policy-silent','ai-crawler-directives-missing',
     'ai-chatbot-present-undisclosed','ai-vendor-undisclosed','ai-generated-content-undisclosed'
   );

do $$
declare
  v_total int;
  v_rules int;
begin
  select count(*) into v_total from muster.scan_rule_history;
  select count(distinct rule_id) into v_rules from muster.scan_rule_history;
  if v_rules <> (select count(*) from muster.scan_rules) then
    raise exception 'backfill covers % rule_ids but scan_rules has % rows -- something was missed',
      v_rules, (select count(*) from muster.scan_rules);
  end if;
  raise notice 'scan_rule_history backfilled: % row(s) across % rule(s)', v_total, v_rules;
end $$;
