-- Three rules that close gaps docs/SCAN-RULES.md names under "what the engine
-- does not check", all on machinery that already exists: the script inventory
-- behind TP-001 and the DoH resolver behind the EMAIL family.
--
-- SEC-014 matters most. OWASP Top 10:2025 added Software Supply Chain Failures
-- at #3, and until now the only thing MUSTER produced for it was TP-001, an
-- inventory: "these third-party scripts run on your site". Subresource Integrity
-- is the control that turns that inventory into a posture question, and it is
-- visible from a single HTTP fetch.
--
-- SEC-014 deliberately EXCLUDES tag managers, analytics and chat widgets. Their
-- files are meant to change; pinning a hash breaks the tag on the vendor's next
-- deploy. "Add SRI to Google Tag Manager" is advice that takes a site down, and
-- a rule that issues it costs more credibility than the finding is worth -- the
-- same reasoning that keeps DKIM out of the EMAIL family. The finding states how
-- many scripts it excluded and points at CSP and vendor review for those,
-- instead of pretending they are fine.
--
-- scan_evidence.kind gains 'dns_caa'. That CHECK is a whitelist in DDL, the same
-- shape as the controls.framework one that broke the register on 2026-09-16 --
-- but evidence kinds are emitted by engine code, not by data a rule author
-- edits, so a constraint is the right tool here and the fix is to extend it in
-- the same migration that emits the new kind. Doing it in the wrong order is how
-- the register broke: the engine shipped a value the schema refused.

alter table muster.scan_evidence drop constraint if exists scan_evidence_kind_check;
alter table muster.scan_evidence add constraint scan_evidence_kind_check
  check (kind in (
    'http_response', 'redirect_chain', 'robots_txt', 'sitemap', 'security_txt',
    'http_probe', 'html_excerpt', 'header_set', 'dns_txt', 'dns_mx', 'dns_caa'
  ));

insert into muster.scan_rules
  (rule_id, category, title, description, default_severity, check_type, framework_refs, remediation, plain_english, active)
values
  ('SEC-014', 'security', 'Third-party scripts load without Subresource Integrity',
   'One or more scripts are loaded from a third-party host without an integrity attribute, so the browser executes whatever that host returns. Tag managers, analytics and chat widgets are excluded: their files change by design and a pinned hash would break them.',
   'medium', 'http_native',
   '{"NIST_CSF": "ID.SC-2", "NIST_CSF_V2": "GV.SC-04", "NIST_800_53": "SR-3, SI-7", "OWASP_TOP10": "A03:2025", "SOC_2": "CC9.2"}'::jsonb,
   'For each third-party script that is a versioned, immutable file -- a pinned library from a CDN -- add integrity="sha384-..." and crossorigin="anonymous" to the tag. Generate the hash from the exact file you intend to serve and pin the version in the URL, because a floating version changes the hash. For tag managers and analytics, SRI does not apply: constrain them with a Content-Security-Policy that names the hosts you accept, and review what the vendor loads.',
   'Some of the code running on your site comes from other companies'' servers, and your visitors'' browsers run whatever those servers send. If one of them is broken into, the attacker''s code runs on your pages. For the libraries that never change, you can pin an exact fingerprint so the browser refuses anything else.',
   true),

  ('SEC-015', 'security', 'No CAA record restricts who may issue certificates',
   'No CAA record is published at the host or any name up to the registrable domain, so any public certificate authority may issue a certificate for this domain.',
   'low', 'http_native',
   '{"NIST_CSF": "PR.DS-2", "NIST_CSF_V2": "PR.DS-02", "NIST_800_53": "SC-17", "OWASP_TOP10": "A02:2025", "CUSTOM": "RFC 8659"}'::jsonb,
   'Publish a CAA record at the apex naming the certificate authorities you actually use, for example: example.com. IN CAA 0 issue "letsencrypt.org". Add an iodef record so you are notified of attempted issuance elsewhere. Check every CA your organisation uses, including any your CDN or host issues on your behalf, before publishing -- a CAA record that omits one will stop renewals.',
   'Right now any certificate company in the world is allowed to issue a certificate for your domain. A CAA record is a public note saying which ones you actually use, so the others are supposed to refuse.',
   true),

  ('EMAIL-008', 'security', 'No MTA-STS policy',
   'The domain accepts mail but publishes no enforcing MTA-STS policy, so a sending server that cannot negotiate TLS falls back to delivering in clear text instead of refusing. Also fires when the TXT record exists with no policy served, or when the policy is in testing mode.',
   'low', 'http_native',
   '{"NIST_CSF": "PR.DS-2", "NIST_CSF_V2": "PR.DS-02", "NIST_800_53": "SC-8", "CUSTOM": "RFC 8461"}'::jsonb,
   'Serve https://mta-sts.<domain>/.well-known/mta-sts.txt with version: STSv1, your MX hosts, and max_age, then publish the _mta-sts TXT record pointing at it. Start at mode: testing with a TLS-RPT address, confirm the reports are clean, and only then move to mode: enforce. Publishing the TXT record without serving the policy file is worse than publishing neither.',
   'Mail sent to you is supposed to travel encrypted, but without this policy a sending server that cannot set up encryption will quietly send it in plain text instead of stopping. This tells senders to refuse rather than downgrade.',
   true)

on conflict (rule_id) do update set
  category = excluded.category, title = excluded.title, description = excluded.description,
  default_severity = excluded.default_severity, check_type = excluded.check_type,
  framework_refs = excluded.framework_refs, remediation = excluded.remediation,
  plain_english = excluded.plain_english, active = excluded.active;

-- Every framework these rules cite must already be in the lookup, or
-- sync_controls fails at insert the way it did on 2026-09-16.
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

do $$
declare v_n integer;
begin
  select count(*) into v_n from muster.scan_rules
  where rule_id in ('SEC-014','SEC-015','EMAIL-008') and active;
  if v_n <> 3 then raise exception 'expected 3 new active rules, found %', v_n; end if;
end $$;