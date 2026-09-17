-- muster_065: AVAIL-003, for a site that answers and refuses us.
--
-- Found by running the new console audit against a real prospect. studyfetch.com
-- returned HTTP 403 to MUSTER-Scanner/1.0 in 120 ms while the plain-HTTP probe
-- got a normal 301, which is a WAF or bot filter declining our user agent, not a
-- site that is down. AVAIL-001 reported it as critical "Site unreachable or
-- returning an error", and the SITREP told the reader in plain English that
-- "Visitors cannot load the site. Nothing else matters until this is fixed,"
-- with remediation pointing at DNS, hosting and TLS.
--
-- Every clause of that is wrong for a site that is up, and it is the exact
-- failure this codebase treats as the worst one available: stating something
-- confident about a page the engine never read. It is the mirror of the
-- PRIV-001 defect in issue #93.
--
-- AVAIL-003 separates "the server answered and refused us" from "nobody can
-- reach this". 401, 403 and 429 only: a 404 homepage is genuinely broken, a 5xx
-- is genuinely an outage, and both stay on AVAIL-001.
--
-- WHY IT IS STILL CRITICAL, which looks wrong and is not. Severity drives
-- posture: critical 25, high 10, medium 4, low 1, subtracted from 100, and the
-- band is green at 85. Filing a refused scan as low would score the site 99 and
-- render it GREEN -- a site MUSTER could not read at all, presented as a clean
-- bill of health. That is the same defect as migration 062's: absence of
-- findings being read as a pass. At critical the site scores 75 amber, which is
-- the honest signal -- this is not a result you can rely on. What changes here
-- is not the weight, it is the claim: the finding now says the scan produced no
-- assessment, instead of asserting an outage and sending someone to check DNS.
--
-- The remediation deliberately answers both readings, because one request cannot
-- tell them apart: if it is bot protection, allow the scanner; if the 403 really
-- is served to everyone, it is an outage after all.
--
-- INACTIVE on purpose. The engine that emits it is not deployed yet, and the
-- standing rule is that a rule waits for its engine -- now enforced at ingest by
-- migration 20260917061404, so leaving it active here would be the back door
-- that migration closed. Activate after a scan reports the engine carrying it.

insert into muster.scan_rules
  (rule_id, category, title, description, default_severity, check_type, framework_refs, remediation, plain_english, active)
values (
  'AVAIL-003',
  'availability',
  'Site could not be assessed: the scanner was refused',
  'The homepage returned 401, 403 or 429 -- the server answered, but declined the request. The engine therefore read no markup, no headers and no cookies for this site, so the HTTP-derived rules produced nothing. DNS-derived rules (SPF, DMARC, CAA, MTA-STS) are unaffected and still ran.',
  'critical',
  'http_native',
  '{"SOC_2":"A1.2","NIST_CSF":"DE.CM-1","NIST_800_53":"SI-4","NIST_CSF_V2":"DE.CM-01"}'::jsonb,
  'If this is your site, allow the MUSTER-Scanner user agent through your WAF, CDN bot protection or rate limiter, then rescan -- until then this scan is not an assessment. If the same status is served to ordinary visitors, it is a genuine outage: treat it as AVAIL-001 and restore service.',
  'MUSTER could not read this site, so this scan does not tell you whether it is secure. The server answered but turned our scanner away, which is usually bot protection rather than a fault.',
  false
)
on conflict (rule_id) do update set
  category = excluded.category, title = excluded.title, description = excluded.description,
  default_severity = excluded.default_severity, check_type = excluded.check_type,
  framework_refs = excluded.framework_refs, remediation = excluded.remediation,
  plain_english = excluded.plain_english, updated_at = now();
