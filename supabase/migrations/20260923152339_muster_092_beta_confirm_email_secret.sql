-- RECOVERED, SECRET REDACTED. Applied live with no file on 2026-09-23
-- (found during the 2026-09-25 migration-ledger audit; see
-- supabase/migrations/README.md). The statement that actually ran called
-- vault.create_secret() with a literal plaintext Resend API key as its first
-- argument. That value is never written to git -- see the header of
-- 20260923135747_muster_087_beta_signup_notify.sql for why this is a security
-- decision, not a documentation nicety. This file's bytes deliberately do not
-- match the ledger's recorded statement for this version.
--
-- This key was superseded twice more the same day (muster_094, muster_095),
-- so the value this migration originally set is not even the one live today.

select vault.create_secret(
  '[REDACTED -- see this file''s header comment; superseded twice the same day, see muster_094 and muster_095]',
  'muster_resend_api_key',
  'Resend API key (sending_access, scoped to mail.muster.partners) used to send beta signup confirmation emails'
) where not exists (select 1 from vault.decrypted_secrets where name = 'muster_resend_api_key');
