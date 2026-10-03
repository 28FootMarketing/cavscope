-- Customer-visible leftovers of the old product name in the rule catalogue. Three rules told a customer
-- "MUSTER could not read this site", "MUSTER does not sign in" and to allow "the MUSTER-Scanner user
-- agent" -- and the scanner has identified itself as CavScope-Scanner since 2026-09-30, so the fix
-- instruction pointed at a user agent that no longer exists. The text is read into every report and
-- into the Findings Glossary, so it is corrected at the source.

update cavscope.scan_rules set
  description = replace(replace(description, 'MUSTER-Scanner', 'CavScope-Scanner'), 'MUSTER', 'CavScope'),
  plain_english = replace(replace(plain_english, 'MUSTER-Scanner', 'CavScope-Scanner'), 'MUSTER', 'CavScope'),
  remediation = replace(replace(remediation, 'MUSTER-Scanner', 'CavScope-Scanner'), 'MUSTER', 'CavScope')
where rule_id in ('AUTH-004', 'AVAIL-003', 'AVAIL-004');
