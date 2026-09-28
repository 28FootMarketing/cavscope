-- MUSTER 087: adds the `dns_ds` scan_evidence kind, needed for SEC-020
-- (DNSSEC) -- see supabase/functions/muster-scan/hardening.ts's
-- evaluateDnssec and index.ts's resolveDs, wired in the same change as this
-- migration.
--
-- scan_evidence.kind is a CHECK-constrained whitelist, and ingest is one
-- transaction: an engine emitting a kind the constraint does not admit fails
-- the WHOLE scan, not just the one rule -- this happened for real on
-- 2026-09-08 when dns_txt/dns_mx shipped ahead of the constraint (muster_041)
-- and again would have for dns_caa had it not been added in the same
-- migration as SEC-015 (muster_061). This migration exists so SEC-020's
-- evidence kind is admitted before -- not after -- any scan can emit it.
--
-- SEC-020 itself (migration 086) is still inactive and stays that way until
-- a scan reports http-native-1.9.0 or later. This migration only makes the
-- evidence kind legal; it does not activate the rule.

alter table muster.scan_evidence drop constraint if exists scan_evidence_kind_check;
alter table muster.scan_evidence add constraint scan_evidence_kind_check
  check (kind in (
    'http_response', 'redirect_chain', 'robots_txt', 'sitemap', 'security_txt',
    'http_probe', 'html_excerpt', 'header_set', 'dns_txt', 'dns_mx', 'dns_caa',
    'dns_ds'
  ));

do $$
declare v_def text;
begin
  select pg_get_constraintdef(oid) into v_def
    from pg_constraint
   where conrelid = 'muster.scan_evidence'::regclass and conname = 'scan_evidence_kind_check';

  if v_def is null then
    raise exception 'scan_evidence_kind_check is missing after the rewrite';
  end if;
  if v_def not like '%dns_ds%' then
    raise exception 'scan_evidence_kind_check does not admit dns_ds: %', v_def;
  end if;
  -- Every pre-existing kind has to survive, or the next scan that emits one
  -- of them fails ingest the moment this deploys.
  if v_def not like '%http_response%' or v_def not like '%redirect_chain%'
     or v_def not like '%robots_txt%' or v_def not like '%sitemap%'
     or v_def not like '%security_txt%' or v_def not like '%http_probe%'
     or v_def not like '%html_excerpt%' or v_def not like '%header_set%'
     or v_def not like '%dns_txt%' or v_def not like '%dns_mx%'
     or v_def not like '%dns_caa%' then
    raise exception 'scan_evidence_kind_check lost a pre-existing kind: %', v_def;
  end if;
end $$;
