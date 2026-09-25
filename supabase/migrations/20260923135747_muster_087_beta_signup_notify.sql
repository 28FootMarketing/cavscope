-- RECOVERED, SECRET REDACTED. Applied live with no file on 2026-09-23
-- (found during the 2026-09-25 migration-ledger audit; see
-- supabase/migrations/README.md). The statement that actually ran called
-- vault.create_secret() with a literal plaintext Telegram bot token as its
-- first argument. That value is never written to git, even for a historical
-- record -- committing a live, working credential to repo history is a
-- security incident, not a documentation nicety, and it stays exploitable in
-- every clone and fork for as long as the object exists in history.
--
-- Because of the redaction below, this file's bytes do NOT match the ledger's
-- recorded statement for this version, and a ledger cross-check will report
-- it as diverged. That divergence is deliberate and is the correct outcome:
-- see the redaction note this comment leaves in its place.
--
-- The real value lives only in muster's project vault (vault.decrypted_secrets,
-- name 'muster_telegram_bot_token') and, per the original migration's own
-- comment, was "copied from hub aiva_telegram_bot_token" -- meaning this may be
-- the SAME bot token also used by AIVA elsewhere in the 28FS stack, not a
-- MUSTER-only credential. Two things follow from that, neither decided here:
-- whether the token should be rotated now that it has sat in this project's
-- migration ledger (supabase_migrations.schema_migrations) in plaintext since
-- 2026-09-23, and whether MUSTER should be given its own dedicated bot token
-- instead of reusing AIVA's, so a compromise of one system's database does not
-- expose the other's bot. Both are the owner's call.

select vault.create_secret(
  '[REDACTED -- see this file''s header comment; real value in vault.decrypted_secrets as muster_telegram_bot_token]',
  'muster_telegram_bot_token',
  'Telegram bot token used to notify on new MUSTER beta signups (copied from hub aiva_telegram_bot_token)'
) where not exists (select 1 from vault.decrypted_secrets where name = 'muster_telegram_bot_token');

select vault.create_secret(
  encode(gen_random_bytes(24), 'hex'),
  'muster_beta_notify_secret',
  'Shared secret between the beta-signup DB trigger and the muster-beta-notify Edge Function'
) where not exists (select 1 from vault.decrypted_secrets where name = 'muster_beta_notify_secret');

-- service-role-only accessor for vault secrets, so Edge Functions can fetch
-- them via PostgREST RPC using the auto-injected SUPABASE_SERVICE_ROLE_KEY
create or replace function public.muster_get_secret(p_name text)
returns text
language sql
security definer
set search_path = ''
as $$
  select decrypted_secret from vault.decrypted_secrets where name = p_name;
$$;

revoke all on function public.muster_get_secret(text) from public, anon, authenticated;
grant execute on function public.muster_get_secret(text) to service_role;

-- trigger function: fires the edge function on every new beta signup
create or replace function public.muster_notify_beta_signup()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_secret text;
begin
  select decrypted_secret into v_secret
  from vault.decrypted_secrets
  where name = 'muster_beta_notify_secret';

  perform net.http_post(
    url := 'https://hjowfnzpomzxazmzywxw.supabase.co/functions/v1/muster-beta-notify',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-muster-signal', v_secret
    ),
    body := jsonb_build_object(
      'full_name', new.full_name,
      'company_name', new.company_name,
      'email', new.email,
      'site_url', new.site_url,
      'marketing_consent', new.marketing_consent,
      'created_at', new.created_at
    )
  );
  return new;
end;
$$;

drop trigger if exists trg_muster_beta_signup_notify on public.muster_beta_signups;
create trigger trg_muster_beta_signup_notify
  after insert on public.muster_beta_signups
  for each row execute function public.muster_notify_beta_signup();
