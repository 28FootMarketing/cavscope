-- Fixes the latent bug recorded in muster_035: the "missed" window was a flat
-- 30 minutes, unrelated to each job's schedule. Every muster job currently runs
-- every 15 minutes or less so it held, but any job scheduled less often than
-- every 30 minutes would have reported missed permanently from its first run --
-- a nightly digest would have alarmed forever, which is how an alerting channel
-- gets muted and then ignored.
--
-- muster.cron_period_minutes(schedule) derives each job's period, and the
-- threshold becomes greatest(2 * period, 15 minutes). The floor stops a
-- one-minute job alarming on a single late tick.
--
-- The 15-minute jobs keep exactly the threshold they have today (2 * 15 = 30),
-- so the jobs that motivated the original constant are unaffected. The 5- and
-- 10-minute jobs tighten from 30 to 15 and 20 minutes -- which is the point: a
-- five-minute job silent for half an hour has missed five ticks and should not
-- have to wait for the sixth.
--
--   muster-alert-dispatch-5min        5 min  -> 15 min threshold (was 30)
--   muster-watchdog-10min            10 min  -> 20 min threshold (was 30)
--   muster-scan-due                  15 min  -> 30 min threshold (unchanged)
--   muster-embedding-backfill-15min  15 min  -> 30 min threshold (unchanged)
--   muster-autotriage-15min          15 min  -> 30 min threshold (unchanged)
--
-- muster_035's cold-start guard is preserved and made explicit: the condition is
-- now "has succeeded at least once", so a job with no successful run is still
-- not-yet-due rather than missed.
--
-- WHAT THE PARSER DELIBERATELY REFUSES. It returns NULL for anything it cannot
-- derive with certainty, and NULL is treated as not-missed. Guessing a period
-- wrong in the alarming direction is worse than not alarming: the first costs
-- trust in every future alert, the second is one unmonitored job. What returns
-- NULL: day-of-week or day-of-month constraints, ranges (0-30), steps inside
-- lists, and an hour constraint combined with anything but a single minute.
-- Such a job is monitored for FAILURES -- failure_count is untouched -- just not
-- for silence. If one is ever added, extend this function rather than widening
-- the window.
--
-- Every regex here is written with POSIX classes and bracketed literals instead
-- of backslash escapes. muster_016 and muster_017 exist because backslashes were
-- doubled in transcription; the cheapest defence is to not use any.

create or replace function muster.cron_period_minutes(p_schedule text)
returns integer
language plpgsql
immutable
set search_path to ''
as $fn$
declare
  s          text;
  parts      text[];
  min_f      text;
  hour_f     text;
  vals       int[];
  gap        int;
  max_gap    int;
  i          int;
  n          int;
begin
  s := lower(btrim(coalesce(p_schedule, '')));
  if s = '' then return null; end if;

  if s = '@hourly'                      then return 60;     end if;
  if s in ('@daily', '@midnight')       then return 1440;   end if;
  if s = '@weekly'                      then return 10080;  end if;
  if s = '@monthly'                     then return 43200;  end if;
  if s in ('@yearly', '@annually')      then return 525600; end if;
  if s like '@%'                        then return null;   end if;

  -- pg_cron sub-minute syntax ("30 seconds"). Floored at one minute: the check
  -- has no sub-minute resolution and should not pretend otherwise.
  if s ~ '^[0-9]+[[:space:]]+seconds?$' then return 1; end if;

  parts := regexp_split_to_array(s, '[[:space:]]+');
  if coalesce(array_length(parts, 1), 0) <> 5 then return null; end if;

  min_f  := parts[1];
  hour_f := parts[2];

  -- Any day-of-month, month or day-of-week constraint: not derived.
  if parts[3] <> '*' or parts[4] <> '*' or parts[5] <> '*' then
    return null;
  end if;

  if hour_f = '*' then
    -- Period comes from the minute field alone.
    if min_f = '*' then
      return 1;
    elsif min_f ~ '^[*]/[0-9]+$' then
      n := substring(min_f from 3)::int;
      if n < 1 or n > 59 then return null; end if;
      return n;
    elsif min_f ~ '^[0-9]+$' then
      return 60;                      -- once an hour
    elsif min_f ~ '^[0-9]+(,[0-9]+)+$' then
      select array_agg(v order by v) into vals
      from (select distinct unnest(string_to_array(min_f, ','))::int as v) t;
      if coalesce(array_length(vals, 1), 0) < 2 then return 60; end if;
      if vals[array_length(vals, 1)] > 59 then return null; end if;
      max_gap := 0;
      for i in 1 .. array_length(vals, 1) loop
        if i < array_length(vals, 1) then
          gap := vals[i + 1] - vals[i];
        else
          gap := (vals[1] + 60) - vals[i];        -- wrap into the next hour
        end if;
        if gap > max_gap then max_gap := gap; end if;
      end loop;
      return max_gap;
    else
      return null;                    -- ranges, steps in lists, anything else
    end if;
  end if;

  -- Hour is constrained. Only a single fixed minute is derived; "*/5 9-17 * * *"
  -- and friends have a within-window period and a between-window gap that are
  -- different numbers, and picking either would be wrong half the time.
  if min_f !~ '^[0-9]+$' then
    return null;
  end if;

  if hour_f ~ '^[*]/[0-9]+$' then
    n := substring(hour_f from 3)::int;
    if n < 1 or n > 23 then return null; end if;
    return n * 60;
  elsif hour_f ~ '^[0-9]+$' then
    return 1440;                      -- once a day
  elsif hour_f ~ '^[0-9]+(,[0-9]+)+$' then
    select array_agg(v order by v) into vals
    from (select distinct unnest(string_to_array(hour_f, ','))::int as v) t;
    if coalesce(array_length(vals, 1), 0) < 2 then return 1440; end if;
    if vals[array_length(vals, 1)] > 23 then return null; end if;
    max_gap := 0;
    for i in 1 .. array_length(vals, 1) loop
      if i < array_length(vals, 1) then
        gap := vals[i + 1] - vals[i];
      else
        gap := (vals[1] + 24) - vals[i];         -- wrap into the next day
      end if;
      if gap > max_gap then max_gap := gap; end if;
    end loop;
    return max_gap * 60;
  end if;

  return null;
end
$fn$;

-- Postgres grants EXECUTE to PUBLIC on every new function. muster_021,
-- muster_022 and muster_032 all exist because that default was not undone.
revoke all on function muster.cron_period_minutes(text) from public;

create or replace function public.muster_engine_cron_health_check()
returns table(jobname text, failure_count bigint, missed boolean)
language sql
security definer
set search_path to ''
as $function$
  with last_ok as (
    select d.jobid, max(d.start_time) as at
    from cron.job_run_details d
    where d.status = 'succeeded'
    group by d.jobid
  ),
  recent_failures as (
    select d.jobid, count(*) as failures
    from cron.job_run_details d
    where d.status <> 'succeeded'
      and d.start_time > now() - interval '20 minutes'
    group by d.jobid
  )
  select j.jobname,
         coalesce(f.failures, 0)::bigint as failure_count,
         (
           p.period is not null                     -- schedule we can reason about
           and o.at is not null                     -- muster_035: cold-start guard
           and o.at < now() - make_interval(mins => greatest(2 * p.period, 15))
         ) as missed
  from cron.job j
  cross join lateral (select muster.cron_period_minutes(j.schedule) as period) p
  left join last_ok o on o.jobid = j.jobid
  left join recent_failures f on f.jobid = j.jobid
  where j.jobname like 'muster-%' and j.active;
$function$;

do $$
declare
  v_acl    text;
  v_secdef boolean;
  v_config text;
  v_rows   int;
  v_missed int;
  v_failed int;
  v_bad    text;

  -- schedule -> expected period in minutes; null means "must not be derived"
  v_cases text[][] := array[
    array['*/5 * * * *',        '5'],
    array['*/10 * * * *',       '10'],
    array['*/15 * * * *',       '15'],
    array['7,22,37,52 * * * *', '15'],
    array['* * * * *',          '1'],
    array['0 * * * *',          '60'],
    array['@hourly',            '60'],
    array['@daily',             '1440'],
    array['0 3 * * *',          '1440'],
    array['30 */6 * * *',       '360'],
    array['0 9,17 * * *',       '960'],
    array['0 0 * * 1',          null],
    array['0-30 * * * *',       null],
    array['*/5 9-17 * * *',     null],
    array['not a schedule',     null],
    array['',                   null]
  ];
  v_i int;
  v_got int;
  v_want text;
begin
  for v_i in 1 .. array_length(v_cases, 1) loop
    v_got  := muster.cron_period_minutes(v_cases[v_i][1]);
    v_want := v_cases[v_i][2];
    if v_want is null then
      if v_got is not null then
        raise exception 'cron_period_minutes(%) returned %, expected null', v_cases[v_i][1], v_got;
      end if;
    elsif v_got is distinct from v_want::int then
      raise exception 'cron_period_minutes(%) returned %, expected %', v_cases[v_i][1], v_got, v_want;
    end if;
  end loop;

  -- Every live job must have a derivable period; an undetectable one here would
  -- mean a real job silently unmonitored for silence.
  select string_agg(j.jobname || ' (' || j.schedule || ')', ', ')
    into v_bad
  from cron.job j
  where j.jobname like 'muster-%' and j.active
    and muster.cron_period_minutes(j.schedule) is null;
  if v_bad is not null then
    raise exception 'period not derivable for: %', v_bad;
  end if;

  select array_to_string(p.proacl, ' | '), p.prosecdef, p.proconfig::text
    into v_acl, v_secdef, v_config
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'muster_engine_cron_health_check';

  if v_acl is distinct from 'postgres=X/postgres | service_role=X/postgres' then
    raise exception 'ACL changed to %, expected postgres + service_role only', v_acl;
  end if;
  if not v_secdef then
    raise exception 'function is no longer SECURITY DEFINER';
  end if;
  if v_config is distinct from '{"search_path=\"\""}' then
    raise exception 'search_path config changed to %', v_config;
  end if;

  select array_to_string(p.proacl, ' | ') into v_acl
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'muster' and p.proname = 'cron_period_minutes';
  if v_acl is not null and v_acl like '%=X/%' and v_acl not like '%postgres=X%' then
    raise exception 'cron_period_minutes ACL looks wrong: %', v_acl;
  end if;
  if position('"=X/' in coalesce(v_acl, '')) > 0 or coalesce(v_acl, '') like '=X/%' then
    raise exception 'cron_period_minutes still executable by PUBLIC: %', v_acl;
  end if;

  select count(*), count(*) filter (where missed), coalesce(sum(failure_count), 0)
    into v_rows, v_missed, v_failed
  from public.muster_engine_cron_health_check();

  if v_rows <> 5 then
    raise exception 'expected 5 active muster jobs, got %', v_rows;
  end if;
  if v_missed <> 0 then
    raise exception '% job(s) report missed', v_missed;
  end if;
  if v_failed <> 0 then
    raise exception 'failure_count is %, expected 0', v_failed;
  end if;
end $$;
