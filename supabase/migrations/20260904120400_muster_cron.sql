-- MUSTER phase 1: pg_cron schedule for due scans.
-- Project: mgtmqucaldkaxvxglguw
-- Every 15 minutes: claim due websites (and stale queued scans) and run them through the muster-scan edge function.
-- Uses the house cron_safe_post wrapper so failures land in public.cron_error_log and cora_cron_health_check sees them.

do $$
begin
  if exists (select 1 from cron.job where jobname = 'muster-scan-due') then
    perform cron.unschedule('muster-scan-due');
  end if;
end $$;

select cron.schedule(
  'muster-scan-due',
  '*/15 * * * *',
  $cron$
  select public.cron_safe_post(
    'muster-scan-due',
    'https://mgtmqucaldkaxvxglguw.supabase.co/functions/v1/muster-scan',
    jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'supabase_anon_key' limit 1),
      'x-muster-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'muster_cron_secret' limit 1)),
    jsonb_build_object('mode', 'due', 'limit', 3),
    150000);
  $cron$
);
