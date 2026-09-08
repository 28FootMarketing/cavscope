-- Drops the temporary endpoint muster_033 created, now that
-- muster_ghl_webhook_secret is in this project's vault and matches the source
-- byte for byte:
--
--   vault value md5 on both projects        23fdaffd2e7cb37300cd96fa15dd6249
--   public.muster_ghl_webhook_secret() md5  23fdaffd2e7cb37300cd96fa15dd6249
--
-- The second line is the one that matters: it is the RPC muster-ghl-webhook
-- actually calls, so it proves the function will now compare against the same
-- value GHL is configured to send rather than 401ing on a null.
--
-- The token in muster_033 is dead from this point. Left in that file rather
-- than scrubbed, for the same reason as muster_023's and muster_030's: this
-- directory is a history. Do not reuse the value.

drop function if exists public.muster_vault_import(text, text, text);

do $$
begin
  if exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'muster_vault_import'
  ) then
    raise exception 'muster_vault_import still present after drop';
  end if;

  if (select md5(public.muster_ghl_webhook_secret())) is distinct from '23fdaffd2e7cb37300cd96fa15dd6249' then
    raise exception 'muster_ghl_webhook_secret does not resolve to the expected value';
  end if;
end $$;
