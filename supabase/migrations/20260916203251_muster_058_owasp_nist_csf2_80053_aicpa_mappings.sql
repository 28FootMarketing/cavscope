-- Framework mapping pass: OWASP (absent entirely), NIST CSF 2.0 and SP 800-53
-- (CSF refs were all superseded 1.1 identifiers), and a wider SOC 2 / AICPA TSC
-- surface. Data only: no scan rule changes its logic, and the engine is untouched.
--
-- muster.controls is a projection of scan_rules.framework_refs via
-- muster.sync_controls(), so the register grows from this automatically. Nothing
-- here restates a standard's text -- muster_044's first principle -- because a
-- slightly-wrong rendering of a SOC 2 criterion in front of a client is the
-- expensive failure in a compliance product.
--
-- WHY CSF 2.0 IS A CORRECTION, NOT AN ADDITION. All 24 NIST_CSF references were
-- CSF 1.1 identifiers, and CSF 2.0 (Feb 2024) withdrew them. The worst case was
-- TP-001 citing ID.SC-2: supply chain moved out of IDENTIFY entirely and became
-- GV.SC under the new GOVERN function, so a prospect's GRC team working in 2.0
-- could not reconcile the reference at all. SEC-012 is also re-pointed: it cited
-- RS.CO-1 (personnel know their roles), where CSF 2.0 added ID.RA-08, which is
-- literally "processes for receiving, analyzing, and responding to vulnerability
-- disclosures" -- exactly what a security.txt file is.
--
-- 1.1 references are KEPT alongside 2.0. Buyers mid-transition still ask in 1.1,
-- and dropping them would break continuity in every SITREP already delivered.
--
-- WHAT IS DELIBERATELY NOT HERE: OWASP ASVS. ASVS 5.0 renumbered its chapters
-- against 4.0 and the current numbering could not be verified from this
-- environment. Guessing control identifiers is the one thing a compliance
-- product must never do, so ASVS waits for someone with the document open.
--
-- SCOPE LIMIT, which the register already states per row: these are references
-- to what MUSTER observes on the public web surface. Mapping a rule to A02:2025
-- says the finding belongs to that category, NOT that MUSTER tests the category.
-- MUSTER is HTTP-native with no browser and no authenticated crawl, so most of
-- the Top 10 (injection, access control, auth) is out of reach by construction.

-- Display names, so the register reads as a client expects rather than as
-- underscore-separated keys. Previously the title was replace(framework,'_',' '),
-- which gave "NIST CSF PR.DS-2" with no version and would have given
-- "OWASP TOP10 A02:2025". Versions appear only where they are known to be
-- correct for the references actually stored.
create or replace function muster.framework_label(p_framework text)
returns text language sql immutable set search_path to '' as $$
  select case p_framework
    when 'NIST_CSF'             then 'NIST CSF 1.1'
    when 'NIST_CSF_V2'          then 'NIST CSF 2.0'
    when 'NIST_800_53'          then 'NIST SP 800-53 Rev. 5'
    when 'OWASP_TOP10'          then 'OWASP Top 10:2025'
    when 'OWASP_SECURE_HEADERS' then 'OWASP Secure Headers'
    when 'SOC_2'                then 'SOC 2 (AICPA TSC)'
    else replace(p_framework, '_', ' ')
  end;
$$;

update muster.scan_rules r
   set framework_refs = r.framework_refs || m.add_text::jsonb,
       updated_at = now()
  from (values
    -- Transport security. A02:2025 (Security Misconfiguration) rose to #2 in the
    -- 2025 Top 10, and it is the category almost every SEC rule belongs to.
    ('SEC-001', '{"NIST_CSF_V2":"PR.DS-02","NIST_800_53":"SC-8","OWASP_TOP10":"A02:2025","SOC_2":"CC6.7"}'),
    ('SEC-002', '{"NIST_CSF_V2":"PR.DS-02","NIST_800_53":"SC-8","OWASP_TOP10":"A02:2025","OWASP_SECURE_HEADERS":"Strict-Transport-Security","SOC_2":"CC6.7"}'),
    ('SEC-003', '{"NIST_CSF_V2":"PR.DS-02","NIST_800_53":"SC-8","OWASP_TOP10":"A02:2025","OWASP_SECURE_HEADERS":"Strict-Transport-Security","SOC_2":"CC6.7"}'),
    ('SEC-010', '{"NIST_CSF_V2":"PR.DS-02","NIST_800_53":"SC-8","OWASP_TOP10":"A02:2025","SOC_2":"CC6.7"}'),
    ('SEC-013', '{"NIST_CSF_V2":"PR.DS-02","NIST_800_53":"SC-8","OWASP_TOP10":"A02:2025","SOC_2":"CC6.7"}'),

    -- Response headers. PR.PT-3 (least functionality) was withdrawn in 2.0; its
    -- meaning sits in PR.PS-01, configuration management practices.
    -- SEC-004 keeps SOC_2 CC6.6 unchanged: CSP is a boundary control, not a
    -- transmission one, so CC6.7 would be the wrong criterion to add.
    ('SEC-004', '{"NIST_CSF_V2":"PR.PS-01","NIST_800_53":"SC-18","OWASP_TOP10":"A02:2025","OWASP_SECURE_HEADERS":"Content-Security-Policy"}'),
    ('SEC-005', '{"NIST_CSF_V2":"PR.PS-01","NIST_800_53":"SC-18","OWASP_TOP10":"A02:2025","OWASP_SECURE_HEADERS":"X-Frame-Options","SOC_2":"CC6.6"}'),
    ('SEC-006', '{"NIST_CSF_V2":"PR.PS-01","NIST_800_53":"CM-6","OWASP_TOP10":"A02:2025","OWASP_SECURE_HEADERS":"X-Content-Type-Options","SOC_2":"CC6.6"}'),
    -- Referrer leakage is an information-flow problem, hence AC-4 rather than SC-8.
    ('SEC-007', '{"NIST_CSF_V2":"PR.DS-02","NIST_800_53":"AC-4","OWASP_TOP10":"A02:2025","OWASP_SECURE_HEADERS":"Referrer-Policy"}'),
    -- Permissions-Policy disables browser features a site does not use, which is
    -- least functionality almost verbatim.
    ('SEC-008', '{"NIST_CSF_V2":"PR.PS-01","NIST_800_53":"CM-7","OWASP_TOP10":"A02:2025","OWASP_SECURE_HEADERS":"Permissions-Policy"}'),
    ('SEC-009', '{"NIST_CSF_V2":"PR.PS-01","NIST_800_53":"CM-6","OWASP_TOP10":"A02:2025","OWASP_SECURE_HEADERS":"Server"}'),

    -- Cookie flags span misconfiguration and session handling, so both Top 10
    -- categories are recorded. sync_controls splits on comma, giving one control
    -- row per reference. Existing SOC_2 CC6.1 is restated so the merge keeps it.
    ('SEC-011', '{"NIST_CSF_V2":"PR.DS-01","NIST_800_53":"SC-23","OWASP_TOP10":"A02:2025, A07:2025","OWASP_SECURE_HEADERS":"Set-Cookie","SOC_2":"CC6.1, CC6.7"}'),

    -- security.txt: see the header note on ID.RA-08. CC2.3 is the TSC criterion
    -- for communicating with external parties about the system.
    ('SEC-012', '{"NIST_CSF_V2":"ID.RA-08","NIST_800_53":"RA-5","SOC_2":"CC2.3"}'),

    -- Email authentication. No OWASP reference: SPF and DMARC are not web
    -- application risks and forcing them into the Top 10 would be dishonest.
    ('EMAIL-001', '{"NIST_CSF_V2":"PR.DS-02","NIST_800_53":"SI-8"}'),
    ('EMAIL-002', '{"NIST_CSF_V2":"PR.DS-02","NIST_800_53":"SI-8"}'),
    ('EMAIL-003', '{"NIST_CSF_V2":"PR.DS-02","NIST_800_53":"SI-8"}'),
    ('EMAIL-004', '{"NIST_CSF_V2":"PR.DS-02","NIST_800_53":"SI-8"}'),
    ('EMAIL-005', '{"NIST_CSF_V2":"PR.DS-02","NIST_800_53":"SI-8"}'),
    ('EMAIL-006', '{"NIST_CSF_V2":"DE.CM-01","NIST_800_53":"AU-6"}'),
    ('EMAIL-007', '{"NIST_CSF_V2":"PR.DS-02","NIST_800_53":"SI-8"}'),

    -- Privacy. The PT family is 800-53 Rev 5's PII processing and transparency
    -- controls; P1.1 and P2.1 are TSC privacy criteria for notice and consent.
    ('PRIV-001', '{"NIST_800_53":"PT-5","SOC_2":"P1.1"}'),
    ('PRIV-002', '{"NIST_800_53":"PT-4","SOC_2":"P2.1"}'),
    ('PRIV-003', '{"NIST_CSF_V2":"PR.DS-02","NIST_800_53":"SC-8","OWASP_TOP10":"A02:2025, A03:2025","SOC_2":"CC6.7"}'),

    -- Third party. A03:2025 Software Supply Chain Failures is new at #3 in the
    -- 2025 Top 10, and an inventory of the third-party scripts a site executes is
    -- the most direct evidence of it MUSTER produces. GV.SC-04 is where CSF 2.0
    -- put "suppliers are known and prioritized", replacing 1.1's ID.SC-2.
    ('TP-001', '{"NIST_CSF_V2":"GV.SC-04","NIST_800_53":"SR-3, SA-9","OWASP_TOP10":"A03:2025"}'),

    -- Availability. PR.DS-4 was withdrawn in 2.0 and its meaning moved to
    -- PR.IR-04, adequate resource capacity.
    ('AVAIL-001', '{"NIST_CSF_V2":"DE.CM-01","NIST_800_53":"SI-4"}'),
    ('AVAIL-002', '{"NIST_CSF_V2":"PR.IR-04","NIST_800_53":"SC-5"}')
  ) as m(rule_id, add_text)
 where r.rule_id = m.rule_id
   and r.active;