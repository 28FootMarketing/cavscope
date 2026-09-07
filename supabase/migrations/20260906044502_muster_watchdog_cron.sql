-- Schedules muster-watchdog, which opens and ages muster.incidents.
--
-- Recovered from supabase_migrations.schema_migrations version 20260906044502
-- (name muster_watchdog_cron), which was applied to the live project but had no
-- file in this repo. Without it, a rebuild created the incidents table and the
-- watchdog RPCs and then nothing ever ran them.

select cron.schedule(
  'muster-watchdog-10min',
  '*/10 * * * *',
  $$
  select public.cron_safe_post(
    'muster-watchdog-10min',
    'https://mgtmqucaldkaxvxglguw.supabase.co/functions/v1/muster-watchdog',
    jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'supabase_anon_key' limit 1),
      'x-muster-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'muster_cron_secret' limit 1)),
    '{}'::jsonb,
    30000);
  $$
);
