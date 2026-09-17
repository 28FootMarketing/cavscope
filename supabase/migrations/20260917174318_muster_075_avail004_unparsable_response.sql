-- MUSTER 075: AVAIL-004, a response the HTTP client received and refused to parse.
--
-- WHY
--
-- Scan 60 against https://hpsd.k12.pa.us/ (Hanover Public School District) came
-- back with AVAIL-001 at critical: "Site unreachable or returning an error",
-- whose plain_english reads "Visitors cannot load the site. Nothing else matters
-- until this is fixed," and whose remediation points at DNS, hosting and TLS.
--
-- The site was up. It returned HTTP 200 with a full 83 KB body to a lenient
-- client in the same minute, and this engine's own plain-HTTP HEAD probe got 200
-- from the same host inside the same scan -- which is how the report managed to
-- say the site was unreachable and report on its redirect behaviour (SEC-001) at
-- the same time. The actual failure was
--
--   client error (SendRequest): invalid HTTP header parsed
--
-- Reproduced on rescan 61, byte-identical. So it is a property of the origin's
-- response, not a blip.
--
-- That is the same defect AVAIL-003 was added for six hours earlier, arriving
-- through a different door: a confident claim about a page the engine never
-- read. AVAIL-003 covered "the server answered and declined us". This covers
-- "the server answered and we could not parse it".
--
-- WHAT IT CLAIMS, AND WHAT IT DOES NOT
--
-- It does not claim the site is broken for visitors -- browsers are lenient and
-- this one loads. It does not claim the scan found anything about the site's
-- security, and says so: every HTTP-derived rule produced nothing, so the score
-- is an unassessed target rather than a clean one. What it does claim is
-- narrow and checkable: response bytes arrived and failed HTTP parsing, and
-- clients built on strict parsers -- monitors, proxies, integrations, other
-- scanners -- fail the same way.
--
-- The classifier is deliberately tight (supabase/functions/muster-scan/
-- availability.ts). hyper raises these errors only after a response has begun
-- arriving; DNS, connect and TLS failures produce different messages because
-- they happen before any response exists. So a match is positive evidence that
-- a server answered rather than a guess. Anything unrecognised stays on
-- AVAIL-001, because misclassifying in that direction would hide a real outage,
-- which is worse than the defect this fixes.
--
-- SEVERITY
--
-- critical, for AVAIL-003's reason (migration 20260917071020): weights are
-- critical 25, high 10, medium 4, low 1, from 100, green at 85. Filing an
-- unreadable scan as low would score a site nobody could read at 99/100 and
-- render it GREEN -- absence of findings read as a pass, which is what
-- migration 062 exists to prevent.
--
-- INACTIVE ON PURPOSE
--
-- The standing rule: a rule waits for the engine that emits it. Since
-- 20260917061404, muster.engine_ingest drops findings whose rule is inactive and
-- reports the count as skipped_inactive, so this row cannot reach a register
-- before the engine ships. Engine floor is http-native-1.6.0 -- a floor, not an
-- equality (see 20260916210100, which named a version that was superseded twice
-- and never deployed). Activate in a separate migration once an ingest from
-- 1.6.0 or later is observed.

insert into muster.scan_rules (
  rule_id, category, title, description, default_severity, check_type,
  framework_refs, remediation, plain_english, active
) values (
  'AVAIL-004',
  'availability',
  'Site could not be assessed: the response was not valid HTTP',
  'The server began sending a response and the HTTP client rejected it during parsing, so the request was abandoned with no status, headers or body. The host is answering -- this is not an outage -- but the engine read nothing over HTTP, so the HTTP-derived rules produced nothing for this site. DNS-derived rules (SPF, DMARC, CAA, MTA-STS) are unaffected and still ran.',
  'critical',
  'http_native',
  '{"SOC_2":"A1.2","NIST_CSF":"DE.CM-1","NIST_800_53":"SI-4","NIST_CSF_V2":"DE.CM-01"}'::jsonb,
  'Capture the raw response headers from the origin (curl -sv, or a packet capture) and compare them against RFC 9110 section 5: the usual causes are a header name containing a space or a control character, a duplicated or malformed Content-Length, an obsolete line fold, or a non-conformant header injected by an appliance in front of the origin. Fix it at whichever hop emits it, then rescan -- until then this scan is not an assessment of the site. If the response is in fact conformant, the finding still stands as evidence that a widely used HTTP parser rejects it.',
  'MUSTER could not read this site, so this scan does not tell you whether it is secure. Your server answered but sent something our HTTP client could not parse. A browser is more forgiving and the site may look fine, while monitoring tools, proxies and integrations that are stricter will fail the same way.',
  false
)
on conflict (rule_id) do nothing;

-- Assertions: the row exists, it is inactive, and nothing else moved.
do $$
declare
  v_active boolean;
  v_sev text;
  v_total int;
  v_inactive int;
begin
  select active, default_severity into v_active, v_sev
    from muster.scan_rules where rule_id = 'AVAIL-004';
  if v_active is null then
    raise exception 'AVAIL-004 was not inserted';
  end if;
  if v_active then
    raise exception 'AVAIL-004 must ship inactive; the engine emitting it is not deployed yet';
  end if;
  if v_sev <> 'critical' then
    raise exception 'AVAIL-004 severity is %, expected critical', v_sev;
  end if;

  select count(*), count(*) filter (where not active) into v_total, v_inactive
    from muster.scan_rules;
  if v_inactive <> 1 then
    raise exception 'expected exactly 1 inactive rule (AVAIL-004), found %', v_inactive;
  end if;
  raise notice 'AVAIL-004 added inactive; % rules total', v_total;
end $$;
