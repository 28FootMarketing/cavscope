-- muster_043: GOV-004's plain-English line asserted a verdict it cannot know.
--
-- GOV-004 is an inventory rule, not a pass/fail one. It reports which AI
-- crawlers a robots.txt addresses and which it blocks, whatever the answer.
-- Its catalog text, however, was written as though the answer were always
-- "none":
--
--   "This is a policy choice: allow AI assistants to read the site, or block
--    them. Right now it is unaddressed."
--
-- Once muster.partners published directives for nine AI crawlers, the SITREP
-- for scan 22 carried both sentences at once: the finding said "Addressed:
-- GPTBot, ChatGPT-User, ... Fully blocked: none", and the plain-English
-- paragraph immediately under it said the decision was unaddressed. A client
-- reading that page cannot tell which half to believe, and the half that is
-- wrong is the one written in the voice aimed at executives.
--
-- Same failure as EMAIL-007 one layer up: text that asserts a state the system
-- has not established for this particular finding. Catalog copy is generic by
-- construction, so it must describe what the rule REPORTS, never what it found.
-- The finding's own detail carries the specifics.

update muster.scan_rules
   set plain_english = 'Whether AI assistants may read this site is a policy choice. This lists which crawlers your robots.txt names and which it blocks, so the decision is visible and deliberate rather than accidental.',
       remediation = 'Decide which AI crawlers to allow, then record that decision explicitly in robots.txt. Silence is also a decision, but not a recorded one.'
 where rule_id = 'GOV-004';

do $$
declare
  v_text text;
begin
  select plain_english into v_text from muster.scan_rules where rule_id = 'GOV-004';
  if v_text is null then
    raise exception 'GOV-004 is missing from the catalog';
  end if;
  -- The specific phrase that contradicted a finding must be gone, and no
  -- replacement may assert a state either.
  if v_text ~* 'unaddressed|right now|currently' then
    raise exception 'GOV-004 plain_english still asserts a state: %', v_text;
  end if;

  -- Guard the class, not just this row: no info-severity rule should claim a
  -- verdict in copy that is reused across every finding it produces.
  select string_agg(rule_id, ', ') into v_text
  from muster.scan_rules
  where default_severity = 'info' and plain_english ~* 'right now it is|currently it is';
  if v_text is not null then
    raise exception 'info rules still asserting a verdict in catalog copy: %', v_text;
  end if;
end $$;
