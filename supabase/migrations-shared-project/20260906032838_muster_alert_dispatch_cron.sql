-- Schedules muster-alert-dispatch, which drains muster.notification_outbox.
--
-- Recovered from supabase_migrations.schema_migrations version 20260906032838
-- (name muster_alert_dispatch_cron), which was applied to the live project but
-- had no file in this repo. Without it, a rebuild from supabase/migrations/
-- produced the alert tables and RPCs and then never dispatched anything.
--
-- Dispatched through public.cron_safe_post so a failed HTTP call is recorded in
-- public.edge_invocations rather than being reported as a successful cron run.

select cron.schedule(
  'muster-alert-dispatch-5min',
  '*/5 * * * *',
  $$
  select public.cron_safe_post(
    'muster-alert-dispatch-5min',
    'https://mgtmqucaldkaxvxglguw.supabase.co/functions/v1/muster-alert-dispatch',
    jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'supabase_anon_key' limit 1),
      'x-muster-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'muster_cron_secret' limit 1)),
    '{}'::jsonb,
    30000);
  $$
);
