-- Fixes a false critical raised by the watchdog during cutover on 2026-09-08.
--
-- What happened: the five cron jobs were enabled at ~02:44. The watchdog ran at
-- 02:50 and opened `cron_missed:muster-autotriage-15min` at severity critical.
-- The job then ran normally at 02:52 and has run normally since. Incident 2 is
-- closed as expected_validation with the timeline in its closure_evidence.
--
-- Why: `missed` was `coalesce(successes, 0) = 0` over a 30-minute window. A job
-- enabled on a project where it has never run has no successes in any window, so
-- it reads as missed until its first tick lands. Every one of the five was
-- exposed to this; autotriage merely had the longest wait to its next tick
-- (schedule 7,22,37,52 -- eight minutes) and was the one the 02:50 pass caught.
--
-- The guard: `missed` now additionally requires that the job has run at least
-- once at some point. A job with no history at all is treated as not-yet-due
-- rather than missed.
--
-- Why that is safe rather than a blind spot. The worry is a job that is enabled
-- and never fires at all, which this now stays quiet about. In pg_cron that case
-- barely exists: a job that fires and fails still writes a job_run_details row,
-- and that is caught by failure_count, which is untouched here. A job that never
-- writes any row means the scheduler never fired it, which means either the job
-- is inactive -- already filtered by `j.active` -- or the schedule was invalid,
-- which cron.schedule rejects at creation. What is left is the cutover case this
-- migration exists to silence.
--
-- EXISTS per job rather than a distinct scan: there are five muster jobs and
-- cron.job_run_details is a high-churn table with a retention policy, so a
-- correlated existence probe is both cheaper and stable as that table grows.
--
-- SEPARATE LATENT BUG, NOT FIXED HERE. The 30-minute window is a flat constant,
-- not derived from each job's schedule. Every current muster job has a period of
-- 15 minutes or less so the window holds today, but any job scheduled less often
-- than every 30 minutes would report `missed` permanently from its first run.
-- Fixing that means parsing cron expressions to get each job's period, which is
-- a larger change with its own failure modes; it is recorded in
-- MUSTER-PROJECT-LEDGER.md rather than smuggled in here.
--
-- Note also that muster-watchdog/index.ts describes this check as flagging a job
-- "whose last run is older than 2x its own schedule interval". That is not what
-- the SQL has ever done -- the comment describes an intent the implementation
-- does not have. Left alone deliberately: correcting the comment without
-- changing the behaviour it misdescribes would just move the inaccuracy.
--
-- INTENDED DIVERGENCE FROM mgtmqucaldkaxvxglguw. This is applied to this project
-- only. The old project's copy is unchanged, its cron is disabled, and its
-- watchdog no longer runs, so the drift is inert. supabase/migrations-shared-
-- project/ is history and is not added to.

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
         (
           coalesce(r.successes, 0) = 0
           and exists (
             select 1 from cron.job_run_details d2 where d2.jobid = j.jobid
           )
         ) as missed
  from cron.job j
  left join recent r on r.jobid = j.jobid
  where j.jobname like 'muster-%' and j.active;
$function$;

do $$
declare
  v_acl text;
  v_secdef boolean;
  v_config text;
  v_rows int;
  v_missed int;
  v_failed int;
begin
  select array_to_string(p.proacl, ' | '), p.prosecdef, p.proconfig::text
    into v_acl, v_secdef, v_config
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'muster_engine_cron_health_check';

  -- create or replace preserves the ACL, but muster_021/022/032 are three
  -- separate occasions when a grant moved without anyone intending it.
  if v_acl is distinct from 'postgres=X/postgres | service_role=X/postgres' then
    raise exception 'ACL changed to %, expected postgres + service_role only', v_acl;
  end if;
  if not v_secdef then
    raise exception 'function is no longer SECURITY DEFINER';
  end if;
  if v_config is distinct from '{"search_path=\"\""}' then
    raise exception 'search_path config changed to %', v_config;
  end if;

  -- All five jobs are enabled and have run successfully by now, so the correct
  -- answer for every row is missed=false, failure_count=0. If the guard were
  -- inverted this would catch it.
  select count(*), count(*) filter (where missed), coalesce(sum(failure_count), 0)
    into v_rows, v_missed, v_failed
  from public.muster_engine_cron_health_check();

  if v_rows <> 5 then
    raise exception 'expected 5 active muster jobs, got %', v_rows;
  end if;
  if v_missed <> 0 then
    raise exception '% job(s) still report missed after the guard', v_missed;
  end if;
  if v_failed <> 0 then
    raise exception 'failure_count is %, expected 0 -- the guard must not mask real failures', v_failed;
  end if;
end $$;
