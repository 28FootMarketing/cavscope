-- muster_040: the EMAIL-* rule family.
--
-- MUSTER checked 31 things across six categories and none of them was whether
-- somebody can send mail as the client's domain. Missing SPF and DMARC is the
-- most common way a business gets impersonated, and it is invisible over HTTP,
-- which is why a scanner built entirely on fetch() never saw it.
--
-- Six rules, all decidable from two TXT lookups: the apex for SPF, _dmarc for
-- DMARC. No new category is introduced -- these sit in 'security', because that
-- is where a tenant looks for "can someone pretend to be us", and because the
-- risk register already promotes security findings.
--
-- DKIM is deliberately absent. A DKIM record lives at
-- <selector>._domainkey.<domain> and the selector is chosen by whatever sends
-- the mail, so it cannot be enumerated from outside. A "no DKIM" finding would
-- be a guess, and probing common selectors would produce false positives on
-- correctly configured domains. That costs more credibility than the finding is
-- worth.
--
-- Severity reasoning:
--   high    the domain is spoofable today (no SPF, no DMARC, or SPF that
--           authorises everyone)
--   medium  protection is published but does not act (multiple SPF records,
--           which RFC 7208 makes a permerror; or DMARC p=none)
--   low     protection acts but nobody is watching (no rua)

insert into muster.scan_rules
  (rule_id, category, title, description, default_severity, check_type, framework_refs, remediation, plain_english, active)
values
  ('EMAIL-001', 'security', 'No SPF record',
   'No v=spf1 TXT record published at the organizational domain.',
   'high', 'http_native',
   '{"NIST_CSF": "PR.DS-2", "CUSTOM": "RFC 7208"}'::jsonb,
   'Publish a TXT record at the domain apex starting v=spf1, listing every service that sends mail for you, and ending in ~all or -all.',
   'Anyone on the internet can send email that appears to come from your domain.',
   true),

  ('EMAIL-002', 'security', 'SPF does not restrict senders',
   'The SPF record ends in +all (authorise everyone) or ?all (neutral), so it asserts no usable policy.',
   'high', 'http_native',
   '{"NIST_CSF": "PR.DS-2", "CUSTOM": "RFC 7208"}'::jsonb,
   'End the SPF record in ~all (softfail) or -all (fail). Never +all, which authorises every sender, and not ?all, which declines to say.',
   'Your domain looks protected but is not. The record permits anyone to send as you.',
   true),

  ('EMAIL-003', 'security', 'Multiple SPF records',
   'More than one v=spf1 TXT record is published. RFC 7208 section 4.5 requires receivers to treat this as a permanent error.',
   'medium', 'http_native',
   '{"NIST_CSF": "PR.DS-2", "CUSTOM": "RFC 7208 s4.5"}'::jsonb,
   'Merge every v=spf1 record into a single TXT record. Combine the include: mechanisms rather than publishing one record per provider.',
   'You have two SPF records, so receiving servers ignore both. The protection is there on paper and absent in practice.',
   true),

  ('EMAIL-004', 'security', 'No DMARC record',
   'No v=DMARC1 TXT record found at _dmarc for the domain or its organizational parent.',
   'high', 'http_native',
   '{"NIST_CSF": "PR.DS-2", "CUSTOM": "RFC 7489"}'::jsonb,
   'Publish a TXT record at _dmarc.<domain> starting v=DMARC1. Begin with p=none and a rua= address, read the reports, then move to quarantine and reject.',
   'Nothing tells receiving servers what to do with forged mail from your domain, so they deliver it.',
   true),

  ('EMAIL-005', 'security', 'DMARC is not enforcing',
   'The DMARC record specifies p=none, or carries no p= tag at all, so receivers are asked to report but not to act.',
   'medium', 'http_native',
   '{"NIST_CSF": "PR.DS-2", "CUSTOM": "RFC 7489"}'::jsonb,
   'Once aggregate reports show only legitimate senders failing, move p=none to p=quarantine, then to p=reject.',
   'Your DMARC record watches impersonation but does not stop it. Forged mail is still delivered.',
   true),

  ('EMAIL-006', 'security', 'DMARC has no reporting address',
   'The DMARC record has no rua= tag, so no aggregate reports are delivered to anyone.',
   'low', 'http_native',
   '{"NIST_CSF": "DE.CM-1", "CUSTOM": "RFC 7489"}'::jsonb,
   'Add rua=mailto:<address> to the DMARC record so aggregate reports arrive somewhere a person or a tool reads them.',
   'Nobody is receiving the reports that would show who is sending mail as your domain.',
   true)

on conflict (rule_id) do update set
  category = excluded.category, title = excluded.title, description = excluded.description,
  default_severity = excluded.default_severity, check_type = excluded.check_type,
  framework_refs = excluded.framework_refs, remediation = excluded.remediation,
  plain_english = excluded.plain_english, active = excluded.active, updated_at = now();

do $$
declare n integer;
begin
  select count(*) into n from muster.scan_rules where rule_id like 'EMAIL-%' and active;
  if n <> 6 then raise exception 'expected 6 active EMAIL rules, found %', n; end if;

  select count(*) into n from muster.scan_rules where rule_id like 'EMAIL-%' and category <> 'security';
  if n <> 0 then raise exception '% EMAIL rules landed outside the security category', n; end if;

  -- The severity vocabulary is shared with muster.findings; a typo here would
  -- only surface when the engine first tried to raise one.
  select count(*) into n from muster.scan_rules
   where rule_id like 'EMAIL-%' and default_severity not in ('critical','high','medium','low','info');
  if n <> 0 then raise exception '% EMAIL rules carry an unknown severity', n; end if;
end $$;