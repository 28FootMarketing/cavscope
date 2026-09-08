-- Two cron jobs reference a vault secret that does not exist.
--
-- audio_hub_generate and audio_hub_publish_due both build their Authorization
-- header as:
--
--   'Bearer ' || (select decrypted_secret from vault.decrypted_secrets
--                 where name = 'service_role_key')
--
-- There is no vault secret by that name. The scalar subquery returns NULL, and
-- 'Bearer ' || NULL is NULL, so jsonb_build_object receives a null Authorization
-- and both jobs have been calling their functions with no credential at all --
-- since the jobs were created.
--
-- This was invisible until today. publish-due crashed at module scope on every
-- request (SB_URL unset, see the function's own header), so it returned 500
-- whether or not the caller was authenticated, and the missing header never
-- showed itself. Repairing the function surfaced the second bug immediately:
-- the first authenticated test call after the fix returned 401, using the
-- cron's own credential, because that credential was NULL.
--
-- The repair is to create the secret the jobs already ask for, rather than
-- rewrite two cron definitions to point somewhere else.
--
-- No new secret material is introduced. vault already holds this project's
-- service-role key twice, under brand-scoped names, and they are byte-identical
-- (md5 9f13a0413700a4cf521a2bcf2304da98 for both brd_service_role_key and
-- ros_service_role_key) -- there is one service-role key per Supabase project,
-- so the brand prefixes are naming convention, not separate credentials. This
-- copies that value to the generic name inside the database; the value is never
-- read out, logged, or transported.
--
-- STILL BROKEN, NOT FIXED HERE: article_intelligence_cron_secret is referenced
-- by caw-article-intelligence-nightly-sweep and
-- caw-article-intelligence-weekly-refresh and also does not exist. That one is a
-- shared secret rather than a copy of an existing credential, so its value
-- cannot be derived from anything already in vault. It needs an operator to set
-- it, and both jobs send a NULL header until then.

do $$
begin
  if not exists (select 1 from vault.secrets where name = 'service_role_key') then
    perform vault.create_secret(
      (select decrypted_secret from vault.decrypted_secrets where name = 'brd_service_role_key'),
      'service_role_key',
      'Project service-role JWT. Generic name used by audio_hub_generate and '
      || 'audio_hub_publish_due. Same value as brd_service_role_key / '
      || 'ros_service_role_key -- one service-role key per project.'
    );
  end if;
end $$;
