-- muster_052: a feature flag registry that tells the truth about itself.
--
-- WHY THIS EXISTS. Before this migration muster.feature_flags held 22 rows and
-- the Super Admin console rendered all 22 with a default toggle and a kill
-- switch beside each one. Eleven of those toggles changed nothing at all:
--
--   enforced in SQL  : agent_api, ai_narrative, custom_domain_enabled,
--                      hide_attribution, jurisdiction_advisor, manual_scans,
--                      multi_website, promote_finding_to_risk,
--                      self_serve_onboarding, sitrep_generation,
--                      white_label_enabled
--   enforced nowhere : browser_wcag_engine, client_management_enabled,
--                      commercial_use_enabled, custom_branding_enabled,
--                      enterprise_enabled, partner_dashboard_enabled,
--                      pdf_export, public_status_badge, scheduled_scans,
--                      super_admin_console, telegram_alerts
--
-- A toggle that changes nothing is worse than a missing one: it reports a
-- control that does not exist. Three of those -- scheduled_scans,
-- super_admin_console, telegram_alerts -- read as safety controls.
--
-- Meanwhile ten shipped surfaces had no flag at all (the WCAG audit, the AIO
-- audit, the risk register, control mapping, the evidence library, the
-- remediation plan, board reporting, the plain-English report, governance
-- exceptions, assurance testing), as did three platform capabilities that
-- should be killable on their own: support impersonation, the ad-hoc URL
-- scanner, and the outbound alert email path.
--
-- This migration adds the metadata and the missing rows. muster_053 wires the
-- four flags worth wiring; muster_054 adds the registry RPCs the console reads.
--
-- enforcement = '{}' means NOTHING reads this key. The console renders that as
-- words, not as a live-looking switch. Keep it honest.

alter table muster.feature_flags
  add column if not exists category    varchar(32) not null default 'other',
  add column if not exists surface     varchar(96),
  add column if not exists enforcement text[]      not null default '{}'::text[],
  add column if not exists wiring_note text;

comment on column muster.feature_flags.category is
  'Grouping for the admin console: workspace, reporting, partner, platform, engine, notifications, unbuilt.';
comment on column muster.feature_flags.surface is
  'What the flag gates, named the way a person would say it.';
comment on column muster.feature_flags.enforcement is
  'Where this flag is actually read: any of sql, app, edge. Empty array means NOTHING reads it -- the toggle is decoration. tests/ui/flag-registry.test.ts checks the app claims against app.html.';
comment on column muster.feature_flags.wiring_note is
  'For an unwired flag, why it is unwired and what would wire it.';

alter table muster.feature_flags drop constraint if exists feature_flags_enforcement_check;
alter table muster.feature_flags add constraint feature_flags_enforcement_check
  check (enforcement <@ array['sql','app','edge']);

alter table muster.feature_flags drop constraint if exists feature_flags_category_check;
alter table muster.feature_flags add constraint feature_flags_category_check
  check (category in ('workspace','reporting','partner','platform','engine','notifications','unbuilt','other'));

update muster.feature_flags set category = v.category, surface = v.surface,
       enforcement = v.enforcement, wiring_note = v.wiring_note
from (values
  ('agent_api',                 'platform',      'Agent API key issuance via muster-agent',                      array['sql'],       null),
  ('ai_narrative',              'reporting',     'LLM executive narrative in the SITREP',                        array['sql','edge'],null),
  ('custom_domain_enabled',     'partner',       'Workspace served from the tenant''s own domain',               array['sql'],       null),
  ('hide_attribution',          'reporting',     'The "Prepared by MUSTER" line on reports',                     array['sql'],       null),
  ('jurisdiction_advisor',      'workspace',     'Law advisories by country and state',                          array['sql','app'], null),
  ('manual_scans',              'engine',        'On-demand scan from the workspace',                            array['sql'],       null),
  ('multi_website',             'workspace',     'More than one website per organization',                       array['sql'],       null),
  ('promote_finding_to_risk',   'workspace',     'One-click promotion of a finding into the risk register',      array['sql','app'], null),
  ('self_serve_onboarding',     'platform',      'Creating an org and first website without a human',            array['sql'],       null),
  ('sitrep_generation',         'reporting',     'SITREP generation after a completed scan',                     array['sql'],       null),
  ('white_label_enabled',       'partner',       'Tenant branding in place of MUSTER''s',                        array['sql','app'], null),
  ('scheduled_scans',           'engine',        'pg_cron scanning on the website cadence',                      array['sql'],       null),
  ('browser_wcag_engine',       'unbuilt',       'Headless-browser axe-core WCAG engine',                        array[]::text[],
     'Not built. The scanner is HTTP + DOM parsing only; there is no headless browser in muster-scan. Kill switch is on so nothing can advertise it.'),
  ('pdf_export',                'unbuilt',       'Server-rendered SITREP PDF',                                   array[]::text[],
     'Not built. app.html''s Plain English view prints from the browser; no server renderer exists. Kill switch is on.'),
  ('public_status_badge',       'unbuilt',       'Public posture badge and status page per website',             array[]::text[],
     'Not built. No public route serves a badge. Kill switch is on.'),
  ('telegram_alerts',           'unbuilt',       'Critical finding alerts to Telegram (CORA relay)',             array[]::text[],
     'Not built. muster-alert-dispatch calls Resend only; there is no Telegram relay in this project. Default is off, which is the only reason this one is not misleading.'),
  ('client_management_enabled', 'partner',       'Creating and managing client orgs under one Partner account',  array[]::text[],
     'Sold on the Partner tier and enforced nowhere: the client-org creation path does not check it. Wiring it means adding the has_flag guard there.'),
  ('commercial_use_enabled',    'partner',       'Right to use MUSTER inside paid client work',                  array[]::text[],
     'A licence term, not a code path. Nothing can enforce it technically; it is here so the entitlement is recorded against the org. Do not present it as a control.'),
  ('custom_branding_enabled',   'partner',       'brand_profiles customization (logo, colors, name)',            array[]::text[],
     'q_brand gates on white_label_enabled instead. Kept as a separate key per spec in case colors-without-white-label is ever sold; until then it is redundant and unread.'),
  ('enterprise_enabled',        'platform',      'Enterprise-scope features (RBAC, custom frameworks)',          array[]::text[],
     'Enterprise scope is set per contract, and none of the named features ship yet. Unread by design; revisit when the first Enterprise org is provisioned.'),
  ('partner_dashboard_enabled', 'partner',       'The multi-client Partner dashboard view',                      array[]::text[],
     'The subclients view in app.html is shown to everyone. Wiring it means gating that nav item -- deliberately not done here because live Partner tenants rely on it.'),
  ('super_admin_console',       'platform',      'The platform console itself',                                  array[]::text[],
     'Access to the console is decided by users.role = super_admin, checked inside every muster_admin_* function. This flag is read by nothing and turning it off would not close the console. It is kept only so the console appears in its own inventory.')
) as v(key, category, surface, enforcement, wiring_note)
where muster.feature_flags.key = v.key;

insert into muster.feature_flags (key, name, description, scope, default_enabled, plan_minimum, kill_switch, category, surface, enforcement, wiring_note)
values
  ('accessibility_audit', 'Accessibility Audit (WCAG 2.2)',
   'The WCAG 2.2 AA audit surface and its A11Y-001..A11Y-007 rules. MUSTER sells accessibility auditing, so this is the one flag whose kill switch has a commercial consequence: turning it off removes the audit a client is paying for.',
   'organization', true, 'trial', false, 'workspace', 'Accessibility (WCAG 2.2) nav item and view', array['app'], null),
  ('aio_audit', 'AIO / GEO Audit',
   'Whether AI assistants can read and cite the site: llms.txt, structured data, crawlability for AI agents.',
   'organization', true, 'trial', false, 'workspace', 'AIO / GEO Audit nav item and view', array['app'], null),
  ('risk_register', 'Risk Register',
   'The risk register: every known issue, its severity, owner and treatment.',
   'organization', true, 'trial', false, 'workspace', 'Risk Register nav item and view', array['app'], null),
  ('control_mapping', 'Control Mapping',
   'Findings mapped to control frameworks (SOC 2, GDPR and the rest). Controls are derived in Postgres from findings; this gates the surface, not the derivation.',
   'organization', true, 'trial', false, 'workspace', 'Control Mapping nav item and view', array['app'], null),
  ('evidence_library', 'Evidence Library',
   'Proof documents that back a compliance claim during an audit.',
   'organization', true, 'starter', false, 'workspace', 'Evidence Library nav item and view', array['app'], null),
  ('remediation_plan', 'Remediation Plan',
   'Fix tracking: owner, due date, progress, escalation.',
   'organization', true, 'trial', false, 'workspace', 'Remediation Plan nav item and view', array['app'], null),
  ('board_reporting', 'Board Reporting',
   'The executive summary view for leadership: critical risks, coverage, open exceptions.',
   'organization', true, 'starter', false, 'reporting', 'Board Reporting nav item and view', array['app'], null),
  ('plain_english_report', 'Plain English Report',
   'The same findings in everyday language, printable for a client. Browser print, not a server-rendered PDF -- that is pdf_export, which is not built.',
   'organization', true, 'trial', false, 'reporting', 'Plain English PDF nav item and view', array['app'], null),
  ('governance_exceptions', 'Governance & Exceptions',
   'Risk appetite thresholds and policy exception approvals.',
   'organization', true, 'pro', false, 'reporting', 'Enterprise Governance nav item and view', array['app'], null),
  ('assurance_testing', 'Assurance Testing',
   'Records of tests proving a control actually works.',
   'organization', true, 'pro', false, 'reporting', 'Assurance Testing nav item and view', array['app'], null),
  ('email_alerts', 'Outbound Alert Email',
   'The risk_opened alert email to org executives and risk owners -- the only application email MUSTER sends (Resend REST, via muster-alert-dispatch). Auth email is GoTrue and is not affected by this flag. Off holds the queue rather than dropping it: pending rows stay pending and drain when it is switched back on.',
   'organization', true, 'trial', false, 'notifications', 'public.muster_engine_claim_alerts', array['sql'], null),
  ('support_impersonation', 'Support Impersonation',
   'Whether a super admin can open a read-only impersonation session at all. Off refuses every new session platform-wide; sessions already open still expire on their own timer. The per-session audit trail is unaffected -- it is append-only and does not depend on this flag.',
   'platform', true, null, false, 'platform', 'public.muster_admin_impersonate_start', array['sql'], null),
  ('admin_url_scanner', 'Ad-hoc URL Scanner',
   'The super admin "Run a URL scan" tool, which scans any URL on the live engine into the internal sandbox org. Off refuses new ad-hoc runs; it does not touch a tenant''s own scans.',
   'platform', true, null, false, 'platform', 'public.muster_admin_run_url', array['sql'], null)
on conflict (key) do update set
  description = excluded.description, category = excluded.category, surface = excluded.surface,
  enforcement = excluded.enforcement, wiring_note = excluded.wiring_note;
