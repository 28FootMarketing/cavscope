-- Schedules muster.autotriage(), which promotes open critical/high/medium
-- findings into muster.risks + muster.remediation_actions and auto-mitigates on
-- rescan.
--
-- This job has NO ledger provenance. cron.job 138 has been running it on the
-- live project since 2026-09-06, but supabase_migrations.schema_migrations has
-- no migration whose SQL mentions 'muster-autotriage-15min' -- it was scheduled
-- by hand, outside apply_migration, so neither this repo nor the migration
-- ledger recorded it. Reconstructed verbatim from cron.job.command on
-- 2026-09-07:
--
--     jobname  muster-autotriage-15min
--     schedule 7,22,37,52 * * * *
--     command  " select muster.autotriage(); "
--
-- The offset schedule is deliberate: it keeps autotriage off the :00/:15/:30/:45
-- boundary where muster-scan-due and muster-embedding-backfill-15min both fire.
--
-- Unlike the other muster jobs this one calls a SQL function rather than an
-- edge function, so it has no HTTP leg and nothing for cron_safe_post to wrap.
-- pg_cron's own success/failure record is the whole truth here.
--
-- Version 20260906032839 is one second after 20260906032658_muster_critical_finding_alerts,
-- which creates muster.autotriage(); it is a placement chosen to sort correctly,
-- not a real applied version.

select cron.schedule(
  'muster-autotriage-15min',
  '7,22,37,52 * * * *',
  $$ select muster.autotriage(); $$
);
