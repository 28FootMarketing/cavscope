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
-- This is the third and, as of 2026-09-25, still-live value of
-- muster_resend_api_key -- the one that actually sends beta signup
-- confirmation emails today. Given three plaintext Resend keys (this one,
-- muster_092's, and muster_094's) have all sat in
-- supabase_migrations.schema_migrations in plaintext since 2026-09-23,
-- rotating the live key at the Resend dashboard and updating the vault
-- secret through a proper RPC (not another raw vault.update_secret literal)
-- is worth the owner's consideration -- not decided or done here.

select vault.update_secret(
  (select id from vault.secrets where name = 'muster_resend_api_key'),
  '[REDACTED -- see this file''s header comment; this is the value live in production as of 2026-09-25]'
);
