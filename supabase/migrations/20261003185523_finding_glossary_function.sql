-- The Findings Glossary reads the rule catalogue through this function, so the glossary cannot drift
-- from what the engine can raise: a rule added to cavscope.scan_rules appears in it with no page edit.
--
-- Anon and authenticated may read it, like cavscope_industries(): these are definitions, not tenant
-- data, and demo mode shows the same list. It returns only what a customer is shown anyway -- title,
-- usual severity, plain-English meaning, how to fix, and whether scans check it today (`checked` is the
-- rule's active flag, so a rule held inactive is labelled "not currently checked", never presented as
-- a check that runs). A retired rule is excluded. framework_refs are deliberately not returned: they
-- are citations, not tests, and a glossary line is the wrong place to carry that distinction.

create or replace function public.cavscope_finding_glossary()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'rule_id', r.rule_id, 'category', r.category, 'title', r.title,
           'severity', r.default_severity, 'plain_english', r.plain_english,
           'remediation', r.remediation, 'checked', r.active)
         order by r.category,
                  case r.default_severity when 'critical' then 1 when 'high' then 2 when 'medium' then 3 when 'low' then 4 else 5 end,
                  r.rule_id), '[]'::jsonb)
  from cavscope.scan_rules r
  where r.retired_at is null;
$$;
revoke all on function public.cavscope_finding_glossary() from public;
grant execute on function public.cavscope_finding_glossary() to anon, authenticated, service_role;
