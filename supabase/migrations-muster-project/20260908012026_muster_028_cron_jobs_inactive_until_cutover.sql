-- The five muster cron schedules, copied from mgtmqucaldkaxvxglguw with every
-- URL rewritten to this project.
--
-- THEY ARE CREATED INACTIVE, AND THAT IS THE POINT. The frontend still talks to
-- the old project and the old project's cron is still running. Activating these
-- now would mean:
--   * muster-scan-due on BOTH projects scanning the same two client websites
--     every 15 minutes, doubling the load we put on customer infrastructure
--   * this project's data immediately diverging from the byte-identical copy
--     just verified (72d0f9272093896fb769e3116c3e1f38 across 42 tables)
--   * muster-alert-dispatch claiming real alert rows with no RESEND_API_KEY set
--     here, burning all 5 retry attempts and dead-lettering them
--
-- Cutover is therefore a single switch, run only after the frontend SB_URL/SB_KEY
-- are repointed and the old project's jobs are disabled:
--
--   select cron.alter_job(jobid, active := true) from cron.job where jobname like 'muster%';
--
-- and on mgtmqucaldkaxvxglguw, in the same maintenance window:
--
--   select cron.alter_job(jobid, active := false) from cron.job where jobname like 'muster%';
--
-- Deactivation goes through cron.alter_job rather than UPDATE cron.job: this
-- role has EXECUTE on the former and no write privilege on the latter.
do $$
declare v_id bigint;
begin
  v_id := cron.schedule('muster-scan-due', '*/15 * * * *', $job$
  select public.cron_safe_post(
    'muster-scan-due',
    'https://hjowfnzpomzxazmzywxw.supabase.co/functions/v1/muster-scan',
    jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'supabase_anon_key' limit 1),
      'x-muster-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'muster_cron_secret' limit 1)),
    jsonb_build_object('mode', 'due', 'limit', 3),
    150000);
  $job$);
  perform cron.alter_job(v_id, active := false);

  v_id := cron.schedule('muster-autotriage-15min', '7,22,37,52 * * * *', $job$ select muster.autotriage(); $job$);
  perform cron.alter_job(v_id, active := false);

  v_id := cron.schedule('muster-alert-dispatch-5min', '*/5 * * * *', $job$
  select public.cron_safe_post(
    'muster-alert-dispatch-5min',
    'https://hjowfnzpomzxazmzywxw.supabase.co/functions/v1/muster-alert-dispatch',
    jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'supabase_anon_key' limit 1),
      'x-muster-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'muster_cron_secret' limit 1)),
    '{}'::jsonb,
    30000);
  $job$);
  perform cron.alter_job(v_id, active := false);

  v_id := cron.schedule('muster-watchdog-10min', '*/10 * * * *', $job$
  select public.cron_safe_post(
    'muster-watchdog-10min',
    'https://hjowfnzpomzxazmzywxw.supabase.co/functions/v1/muster-watchdog',
    jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'supabase_anon_key' limit 1),
      'x-muster-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'muster_cron_secret' limit 1)),
    '{}'::jsonb,
    30000);
  $job$);
  perform cron.alter_job(v_id, active := false);

  v_id := cron.schedule('muster-embedding-backfill-15min', '*/15 * * * *', $job$
  select public.cron_safe_post(
    'muster-embedding-backfill-15min',
    'https://hjowfnzpomzxazmzywxw.supabase.co/functions/v1/muster-backfill-embeddings',
    jsonb_build_object(
      'Content-Type', 'application/json',
      'x-muster-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'muster_cron_secret' limit 1)),
    jsonb_build_object('batch_size', 25, 'type', 'all'),
    55000);
  $job$);
  perform cron.alter_job(v_id, active := false);
end $$;
