-- Self-healing PRD-001 (.planning/selfheal/prds/PRD-001-incident-intake-and-watchdog.md):
-- incident intake table + the muster-watchdog detection cron's backing RPCs.
-- Design rationale, full recovery-playbook registry, and the repair/release
-- policy this feeds into: .planning/selfheal/ARCHITECTURE.md and
-- .planning/selfheal/REPAIR-AND-RELEASE-POLICY.md.

create table muster.incidents (
  id bigint generated always as identity primary key,
  fingerprint text not null,
  source varchar(40) not null check (source in
    ('cron_failure','cron_missed','scan_stuck','scan_silent_failure','alert_dead_letter',
     'commercial_grant_stuck','engine_error_spike','manual')),
  severity varchar(10) not null check (severity in ('info','warning','critical')),
  status varchar(20) not null default 'open' check (status in
    ('open','investigating','recovered','patch_pending','patch_verified',
     'awaiting_release','deployed_awaiting_observation','closed','wont_fix')),
  affected_operation text not null,
  affected_release text,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  occurrence_count int not null default 1,
  evidence jsonb not null default '{}'::jsonb,
  root_cause_classification varchar(30) check (root_cause_classification in
    ('expected_validation','user_misunderstanding','ux_defect','permission_denial',
     'expired_connection','bad_configuration','external_outage','quota_limit',
     'data_drift','race_condition','regression','code_defect','security_incident','unresolved')),
  recovery_action varchar(60),
  recovery_result varchar(20) check (recovery_result in ('recovered','failed','not_applicable')),
  repair_pr_url text,
  closure_evidence jsonb,
  claimed_by text,
  claimed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index incidents_fingerprint_active
  on muster.incidents (fingerprint) where status not in ('closed', 'wont_fix');

create index incidents_status on muster.incidents (status) where status not in ('closed', 'wont_fix');

alter table muster.incidents enable row level security;

create or replace function public.muster_engine_report_incident(
  p_fingerprint text, p_source text, p_severity text, p_affected_operation text,
  p_affected_release text, p_evidence jsonb
) returns bigint
language plpgsql security definer set search_path = '' as $$
declare v_id bigint;
begin
  insert into muster.incidents (fingerprint, source, severity, affected_operation, affected_release, evidence)
  values (p_fingerprint, p_source, p_severity, p_affected_operation, p_affected_release, p_evidence)
  on conflict (fingerprint) where status not in ('closed','wont_fix')
  do update set occurrence_count = muster.incidents.occurrence_count + 1,
    last_seen_at = now(), evidence = excluded.evidence, updated_at = now()
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function public.muster_engine_report_incident(text,text,text,text,text,jsonb) from public, anon, authenticated;
grant execute on function public.muster_engine_report_incident(text,text,text,text,text,jsonb) to service_role;

create or replace function public.muster_admin_incidents(p_status text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if not muster.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(to_jsonb(i) order by i.severity desc, i.last_seen_at desc)
    from muster.incidents i where p_status is null or i.status = p_status), '[]'::jsonb);
end;
$$;
revoke all on function public.muster_admin_incidents(text) from public, anon, authenticated;
grant execute on function public.muster_admin_incidents(text) to authenticated;

create or replace function public.muster_admin_update_incident(p_id bigint, p_status text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if not muster.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  update muster.incidents set status = p_status, updated_at = now(),
    closure_evidence = case when p_note is not null then coalesce(closure_evidence,'{}'::jsonb) || jsonb_build_object('note', p_note, 'at', now()) else closure_evidence end
  where id = p_id;
  return (select to_jsonb(i) from muster.incidents i where i.id = p_id);
end;
$$;
revoke all on function public.muster_admin_update_incident(bigint,text,text) from public, anon, authenticated;
grant execute on function public.muster_admin_update_incident(bigint,text,text) to authenticated;

-- Backing checks for muster-watchdog. cron.job / cron.job_run_details live
-- outside PostgREST's exposed schemas, so the failure/missed check is its
-- own RPC rather than a direct table read from the edge function.
-- Simplification, stated explicitly: "missed" uses a fixed 30-minute
-- no-successful-run window for every muster-* job rather than parsing each
-- job's actual cron expression -- 30 minutes covers 2x the slowest current
-- muster cadence (15 min) with margin. Revisit if a muster job is ever
-- added with a slower cadence than 15 minutes.
create or replace function public.muster_engine_cron_health_check()
returns table(jobname text, failure_count bigint, missed boolean)
language sql security definer set search_path = '' as $$
  select j.jobname,
    coalesce((select count(*) from cron.job_run_details d
      where d.jobid = j.jobid and d.start_time > now() - interval '20 minutes' and d.status <> 'succeeded'), 0) as failure_count,
    not exists (select 1 from cron.job_run_details d
      where d.jobid = j.jobid and d.status = 'succeeded' and d.start_time > now() - interval '30 minutes') as missed
  from cron.job j
  where j.jobname like 'muster-%' and j.active;
$$;
revoke all on function public.muster_engine_cron_health_check() from public, anon, authenticated;
grant execute on function public.muster_engine_cron_health_check() to service_role;

create or replace function public.muster_engine_watchdog_summary()
returns jsonb
language sql security definer set search_path = '' as $$
  select jsonb_build_object(
    'silent_scans', (
      select coalesce(jsonb_agg(jsonb_build_object('scan_id', s.id, 'website_id', s.website_id, 'url', w.url)), '[]'::jsonb)
      from muster.scans s
      join muster.websites w on w.id = s.website_id
      where s.status = 'complete'
        and s.finished_at > now() - interval '20 minutes'
        and (select count(*) from muster.scan_evidence e where e.scan_id = s.id) > 0
        and (select count(*) from muster.findings f where f.last_seen_scan_id = s.id) = 0
        and exists (select 1 from muster.findings f2 where f2.website_id = w.id and f2.last_seen_scan_id <> s.id)
    ),
    'stuck_grants', (
      select coalesce(jsonb_agg(jsonb_build_object('id', g.id, 'email', g.email, 'created_at', g.created_at)), '[]'::jsonb)
      from muster.pending_commercial_grants g
      where g.applied_at is null and g.created_at < now() - interval '48 hours'
    ),
    'dead_letter_alerts', (select count(*) from muster.notification_outbox where status = 'failed' and attempts >= 5),
    'failed_scans_24h', (select count(*) from muster.scans where status = 'failed' and finished_at > now() - interval '24 hours')
  );
$$;
revoke all on function public.muster_engine_watchdog_summary() from public, anon, authenticated;
grant execute on function public.muster_engine_watchdog_summary() to service_role;
