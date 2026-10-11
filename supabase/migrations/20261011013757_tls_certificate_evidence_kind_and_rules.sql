-- SEC-023 / SEC-024 and the tls_certificate evidence kind (engine http-native-1.16.0, tls-cert.ts).
--
-- Two things, in this order, and both must be applied BEFORE the engine that emits them deploys:
--
-- 1. scan_evidence.kind is a CHECK-constrained whitelist and ingest is one transaction, so an engine that
--    emits a kind the constraint does not admit fails the WHOLE scan, not one rule (it happened on
--    2026-09-08 for dns_txt/dns_mx, and muster_101 added dns_ds ahead of its engine for exactly this reason).
--    The constraint is rebuilt from its own current definition plus 'tls_certificate', so a kind this file
--    does not know about cannot be lost, and every old kind is asserted to survive.
--
-- 2. The two rules are added INACTIVE. The engine writes a tls_certificate evidence row on every scan, state
--    "ok" or "unavailable" with a reason, and that row is what proves whether the deployed edge runtime
--    allows the socket the check needs (CLAUDE.md: a raw socket has never been shown to work inside the
--    deployed function). Ingest drops findings for an inactive rule and counts them as skipped_inactive, so
--    nothing reaches a register or a score until a later migration activates them after a deployed scan shows
--    state "ok". A rule that the engine cannot evaluate must never read as a pass.
--
-- Thresholds: SEC-024 fires at 14 days or fewer (high at 7 or fewer), not 30. Automated authorities renew
-- with about 30 days left, so 30 would flag every healthy auto-renewing site for two weeks each cycle; 14 or
-- fewer means renewal has already been failing for about a fortnight. A certificate renewed by hand is
-- covered by the same line, which is a trade-off the remediation text states.

do $mig$
declare
  v_def text;
  v_kinds text[];
  v_old text[];
  v_new text[];
begin
  select pg_get_constraintdef(oid) into v_def
    from pg_constraint
   where conrelid = 'cavscope.scan_evidence'::regclass and conname = 'scan_evidence_kind_check';
  if v_def is null then raise exception 'scan_evidence_kind_check not found'; end if;

  select array_agg(m[1] order by m[1]) into v_old from regexp_matches(v_def, '''([a-z_]+)''', 'g') m;
  if v_old is null or array_length(v_old, 1) < 15 then
    raise exception 'could not read the existing kinds out of: %', v_def;
  end if;
  if 'tls_certificate' = any (v_old) then
    raise notice 'tls_certificate is already admitted';
    return;
  end if;
  v_kinds := array_append(v_old, 'tls_certificate');

  alter table cavscope.scan_evidence drop constraint scan_evidence_kind_check;
  execute format('alter table cavscope.scan_evidence add constraint scan_evidence_kind_check check ((kind)::text = any (%L::text[]))', v_kinds);

  select pg_get_constraintdef(oid) into v_def
    from pg_constraint
   where conrelid = 'cavscope.scan_evidence'::regclass and conname = 'scan_evidence_kind_check';
  v_new := string_to_array((regexp_match(v_def, '\{([^}]*)\}'))[1], ',');
  if v_new is null or not ('tls_certificate' = any (v_new)) then
    raise exception 'tls_certificate not admitted after rewrite: %', v_def;
  end if;
  if not (v_old <@ v_new) or array_length(v_new, 1) <> array_length(v_old, 1) + 1 then
    raise exception 'the rewritten constraint does not hold exactly the old kinds plus one: %', v_def;
  end if;
end
$mig$;

insert into cavscope.scan_rules
  (rule_id, category, title, description, default_severity, check_type, framework_refs, remediation, plain_english, active)
values
  ('SEC-023', 'security', 'TLS certificate has expired',
   'The certificate the site presents on port 443 is past its expiry date. It is read from the server''s own TLS handshake, not from a certificate log, so it reflects what visitors receive. Raised only when the certificate was actually read: a connection that could not be made, a server that accepts only TLS 1.3, or a runtime that does not allow the connection is recorded as evidence and raises nothing. Only the host name the scan ended on is read; other names under the same domain have their own certificates.',
   'critical', 'http_native',
   '{"CUSTOM":"RFC 5280","NIST_CSF":"PR.DS-2","NIST_800_53":"SC-12, SC-17","NIST_CSF_V2":"PR.DS-02","OWASP_TOP10":"A02:2025"}'::jsonb,
   'Renew and install a new certificate for the host name today. If certificates are issued automatically (Let''s Encrypt, your host or your CDN), find out why renewal stopped, such as a changed DNS record, a failing renewal job or a lapsed account, and fix that rather than only replacing this one certificate. Afterwards check every host name that serves the site, including www and any subdomain, presents the new certificate.',
   'The security certificate that proves your site is really yours has run out. Browsers stop visitors with a full-page warning until it is replaced, and many will not let them continue at all.',
   false),
  ('SEC-024', 'security', 'TLS certificate is about to expire',
   'The certificate the site presents on port 443 expires within 14 days (high severity within 7). Certificates from automated authorities are normally renewed with about 30 days left, so 14 or fewer marks renewal that has already been failing for about two weeks; a manually renewed certificate with a month to run is deliberately not flagged. Raised only when the certificate was actually read, and only for the host name the scan ended on.',
   'medium', 'http_native',
   '{"CUSTOM":"RFC 5280","NIST_CSF":"PR.DS-2","NIST_800_53":"SC-12, SC-17","NIST_CSF_V2":"PR.DS-02","OWASP_TOP10":"A02:2025"}'::jsonb,
   'Renew the certificate and install it now; do not wait for the date. If renewal is automatic, find out why it has not happened, such as a changed DNS record, a failing renewal job or a lapsed account, and fix that. For any certificate renewed by hand, set a reminder 30 days before expiry, because this check only speaks up at 14.',
   'The security certificate on your site runs out in under two weeks. When it does, visitors will be blocked with a warning until it is replaced. This usually means automatic renewal has stopped working.',
   false)
on conflict (rule_id) do nothing;

do $$
begin
  if (select count(*) from cavscope.scan_rules where rule_id in ('SEC-023', 'SEC-024') and not active) <> 2 then
    raise exception 'SEC-023 and SEC-024 must exist and be inactive';
  end if;
end $$;
