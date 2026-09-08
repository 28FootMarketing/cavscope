-- The catalog rows behind codes.json.
--   psql "$MUSTER_DB_URL" -At -f export.sql > rows.json
--
-- SCOPE is deliberately NOT selected here, because it is not in the catalog.
-- It is a property of the ENGINE, not of the rule row: it says whether a code
-- produces one verdict for the whole domain or one per page, and that is
-- decided by which step of supabase/functions/muster-scan/index.ts raises it.
--
--   site   step 2  the http://host/ redirect probe                 SEC-001
--          step 5  origin files: robots.txt, sitemap, security.txt GOV-001, GOV-002,
--                                                                  GOV-004, SEC-012
--          step 6  domain DNS: SPF, DMARC, MX                      EMAIL-001..007
--   page   step 1  the fetched response                            AVAIL-001, AVAIL-002, SEC-013
--          step 3  its response headers                            SEC-002..009, SEC-011
--          step 4  its HTML                                        A11Y-*, PRIV-*, SEC-010,
--                                                                  GOV-003, GOV-005, TP-001
--
-- Twelve site-scoped, twenty-six page-scoped. Keep codes.json in step with the
-- engine when a rule moves between steps, and re-derive rather than guessing:
-- a rule labelled site-scoped that actually fires per page will be reported
-- once per crawled page as the crawl widens.
select jsonb_pretty(jsonb_agg(r order by r->>'rule_id'))
from (
  select jsonb_build_object(
    'rule_id', rule_id, 'category', category, 'severity', default_severity,
    'title', title, 'plain_english', plain_english, 'remediation', remediation,
    'frameworks', (
      -- CUSTOM is the catalog's key for a reference outside the named
      -- frameworks; its value already names the standard, so the key is noise.
      select string_agg(case when k = 'CUSTOM' then v else replace(k, '_', ' ') || ' ' || v end, ', ')
      from jsonb_each_text(framework_refs) as t(k, v)
    )) as r
  from muster.scan_rules
  where active
) s;
