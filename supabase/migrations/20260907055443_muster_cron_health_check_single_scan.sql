-- muster-watchdog was failing ~19% of runs with
--   "cron health check failed: canceling statement due to statement timeout"
--
-- muster_engine_cron_health_check ran two correlated subqueries per active
-- muster-% job against cron.job_run_details, which is 214,885 rows / 220 MB and
-- carries only its primary key -- no index on start_time or jobid. Each subquery
-- was a full sequential scan. Measured: 5 scans, 135,762 buffers, 382 ms warm.
-- Warm it fit inside the statement timeout; cold or under load it did not, which
-- is exactly the intermittent failure pattern observed.
--
-- pg_cron owns cron.job_run_details and we are not its owner, so an index is not
-- available to us ("must be owner of table job_run_details"). The fix is to stop
-- scanning five times: filter the 30 minute window once, aggregate by jobid, then
-- left join the job list to it.
--
-- Measured after: 1 scan, 27,234 buffers, 73 ms. Same results, same semantics --
-- a job with no rows in the window still comes back failure_count 0, missed true.
--
-- Worth noting separately: cron.job_run_details holds history back to
-- 2026-06-23 and pg_cron does not prune it. It will keep growing and this query
-- degrades linearly with it. Retention is a decision for the account owner.

create or replace function public.muster_engine_cron_health_check()
returns table(jobname text, failure_count bigint, missed boolean)
language sql
security definer
set search_path to ''
as $function$
  with recent as (
    select d.jobid,
           count(*) filter (
             where d.status <> 'succeeded'
               and d.start_time > now() - interval '20 minutes'
           ) as failures,
           count(*) filter (where d.status = 'succeeded') as successes
    from cron.job_run_details d
    where d.start_time > now() - interval '30 minutes'
    group by d.jobid
  )
  select j.jobname,
         coalesce(r.failures, 0)::bigint as failure_count,
         coalesce(r.successes, 0) = 0 as missed
  from cron.job j
  left join recent r on r.jobid = j.jobid
  where j.jobname like 'muster-%' and j.active;
$function$;
