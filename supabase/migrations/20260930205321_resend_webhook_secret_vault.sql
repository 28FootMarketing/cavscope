-- Delivery tracking's signing secret, from Vault.
--
-- muster-resend-webhook has been deployed since September and has never
-- recorded an event: RESEND_WEBHOOK_SECRET was never set as a function secret
-- and no Resend webhook pointed at it, so the 28 alerts in the outbox with a
-- provider id were "accepted" and nothing ever said whether they arrived.
-- Function env is set by CLI, which nothing in this project's tooling can do;
-- Vault is written by SQL. Same pattern as the inbound mail relay
-- (20260930185418): the env var still wins when set, Vault is the fallback, and
-- a missing secret still fails closed.

create or replace function public.cavscope_engine_resend_webhook_secret()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select decrypted_secret from vault.decrypted_secrets
  where name = 'cavscope_resend_webhook_secret'
  order by created_at desc limit 1;
$$;

revoke all on function public.cavscope_engine_resend_webhook_secret() from public, anon, authenticated;
grant execute on function public.cavscope_engine_resend_webhook_secret() to service_role;

do $$
begin
  if has_function_privilege('anon', 'public.cavscope_engine_resend_webhook_secret()', 'execute')
     or has_function_privilege('authenticated', 'public.cavscope_engine_resend_webhook_secret()', 'execute') then
    raise exception 'cavscope_engine_resend_webhook_secret is callable from a browser';
  end if;
end $$;
