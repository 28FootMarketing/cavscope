-- muster_041: allow DNS evidence kinds on scan_evidence.
--
-- muster_040 added the EMAIL-* rule family, and the engine records the DNS
-- answers those rules are derived from as evidence rows, the same way every
-- other rule cites the HTTP response it read. scan_evidence.kind is a closed
-- CHECK list written when every check was an HTTP fetch, so the first real scan
-- with the new engine failed at ingest:
--
--   ingest failed: new row for relation "scan_evidence" violates check
--   constraint "scan_evidence_kind_check"
--
-- and, because ingest is one transaction, the whole scan failed -- not just the
-- email rules. The catalog rows from muster_040 were live while the engine that
-- produces them could not write. This closes that.
--
-- Two kinds, matching what the engine emits:
--   dns_txt  SPF (apex TXT) and DMARC (_dmarc.<domain> TXT)
--   dns_mx   MX hosts, recorded for context; their absence is not a finding

alter table muster.scan_evidence drop constraint scan_evidence_kind_check;

alter table muster.scan_evidence add constraint scan_evidence_kind_check
  check (kind in (
    'http_response', 'redirect_chain', 'robots_txt', 'sitemap',
    'security_txt', 'http_probe', 'html_excerpt', 'header_set',
    'dns_txt', 'dns_mx'
  ));

do $$
declare
  v_def text;
begin
  select pg_get_constraintdef(oid) into v_def
  from pg_constraint
  where conrelid = 'muster.scan_evidence'::regclass and conname = 'scan_evidence_kind_check';

  if v_def is null then
    raise exception 'scan_evidence_kind_check is missing after the rewrite';
  end if;
  if v_def not like '%dns_txt%' or v_def not like '%dns_mx%' then
    raise exception 'scan_evidence_kind_check does not admit the DNS kinds: %', v_def;
  end if;
  -- The pre-existing kinds have to survive: dropping one would silently break
  -- every HTTP rule the moment the next scan runs.
  if v_def not like '%http_response%' or v_def not like '%header_set%'
     or v_def not like '%html_excerpt%' or v_def not like '%security_txt%'
     or v_def not like '%http_probe%' or v_def not like '%robots_txt%'
     or v_def not like '%sitemap%' or v_def not like '%redirect_chain%' then
    raise exception 'scan_evidence_kind_check lost a pre-existing kind: %', v_def;
  end if;
end $$;
