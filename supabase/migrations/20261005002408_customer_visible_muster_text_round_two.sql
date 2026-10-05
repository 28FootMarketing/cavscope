-- Second pass on the old product name. The first pass searched for the word MUSTER and missed hosts:
-- cavscope.autotriage() still wrote https://app.muster.partners/app#risks into every alert email.
-- Identifiers (muster_* RPCs, muster-* functions, x-muster-api-key) are staged in docs/RENAME-PLAN.md and untouched.

do $$
declare d text;
begin
  d := pg_get_functiondef('cavscope.autotriage()'::regprocedure);
  d := replace(d, 'https://app.muster.partners/app#risks', 'https://cavscope.28footsystems.com/app#risks');
  if d ~* 'muster\.partners' then raise exception 'autotriage still names muster.partners'; end if;
  execute d;
end $$;

update cavscope.brand_profiles
   set report_disclaimer = replace(report_disclaimer, 'MUSTER Assurance Framework', 'CavScope Assurance Framework')
 where report_disclaimer ~ 'MUSTER';

update cavscope.jurisdictions
   set advisory = replace(advisory, 'MUSTER', 'CavScope')
 where advisory ~ 'MUSTER';

update cavscope.remediation_actions
   set description = replace(description, 'MUSTER-Scanner', 'CavScope-Scanner')
 where description ~ 'MUSTER-Scanner';

update cavscope.pricing_settings
   set muster_contact_url = replace(muster_contact_url, 'MUSTER', 'CavScope'),
       partner_contact_url = replace(partner_contact_url, 'MUSTER', 'CavScope'),
       enterprise_contact_url = replace(enterprise_contact_url, 'MUSTER', 'CavScope')
 where (muster_contact_url||partner_contact_url||enterprise_contact_url) ~ 'MUSTER';

-- Alert emails already sent: subjects and bodies a person can still open.
update cavscope.notification_outbox
   set subject = replace(subject, '[MUSTER]', '[CavScope]'),
       body_text = replace(replace(replace(replace(body_text,
         'https://app.muster.partners/', 'https://cavscope.28footsystems.com/'),
         'https://app.muster.28footsystems.com/', 'https://cavscope.28footsystems.com/app'),
         'MUSTER', 'CavScope'), 'Muster', 'CavScope')
 where (subject||coalesce(body_text,'')) ~* 'muster';

update cavscope.websites set name = 'CavScope marketing site (retired host)' where id = 7 and name = 'MUSTER marketing site';
