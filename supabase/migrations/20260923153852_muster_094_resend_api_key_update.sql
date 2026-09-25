-- RECOVERED, SECRET REDACTED. Applied live with no file on 2026-09-23
-- (found during the 2026-09-25 migration-ledger audit; see
-- supabase/migrations/README.md). The statement that actually ran called
-- vault.update_secret() with a literal plaintext Resend API key as its
-- second argument. That value is never written to git -- see the header of
-- 20260923135747_muster_087_beta_signup_notify.sql for why this is a
-- security decision, not a documentation nicety. This file's bytes
-- deliberately do not match the ledger's recorded statement for this
-- version.
--
-- This rotation was itself superseded within two hours by muster_095
-- ("_fix"), which is the value actually live today.

select vault.update_secret(
  (select id from vault.secrets where name = 'muster_resend_api_key'),
  '[REDACTED -- see this file''s header comment; superseded within two hours by muster_095]'
);
