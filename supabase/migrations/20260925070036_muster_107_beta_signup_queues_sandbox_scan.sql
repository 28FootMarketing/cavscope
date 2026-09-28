-- A beta signup now queues a real scan, so the confirmation email's
-- "your site is queued for scanning" is true rather than a promise nobody
-- kept. Before this, muster_beta_signups rows sat at status 'new' with no
-- scan behind them; the first real lead (2026-09-23) had been "queued" for
-- two days with nothing run.
--
-- WHERE THE SCAN GOES: the admin sandbox org (organizations.is_admin_sandbox),
-- through the same muster.do_add_website / muster.do_request_scan pair the
-- super-admin URL runner uses. A prospect is not a tenant and has no org; the
-- sandbox is the documented parking lot for exactly this -- a prospect URL
-- that must never land in a real tenant's register. do_add_website queues the
-- first scan itself; a repeat signup for a site already in the sandbox just
-- requests a fresh scan (do_request_scan dedupes one already in flight).
--
-- WHO OWNS THE WEBSITE ROW: websites.owner_id is NOT NULL and a trigger has no
-- caller, so the lowest super_admin user stands in as "the platform did it" --
-- the same role muster_admin_run_url records for whichever admin clicks.
--
-- scans.trigger is CHECK-constrained to scheduled|manual|api|onboarding, so
-- these scans are 'manual', matching the admin runner. The signup -> scan link
-- is recorded on the signup row (scan_website_id, scan_id) rather than by
-- widening an engine-facing constraint.
--
-- FAILURE IS RECORDED, NEVER RAISED: the queue step is wrapped so a failure
-- (an unreachable-looking URL that fails do_add_website's stricter regex, the
-- sandbox website limit, anything) lands in scan_error on the signup row and
-- the signup itself still commits -- losing a lead to a scan-queue error would
-- be the wrong trade.
--
-- GRANTS: anon and authenticated held table-level ALL on this table (Supabase
-- defaults): INSERT, UPDATE, DELETE and TRUNCATE, with only RLS's single
-- insert policy standing between the publishable key and the leads table.
-- Adding scan_id / scan_website_id to a table the browser can insert into
-- would also have let the browser set them. Both are fixed the way this repo
-- fixes engine RPC grants: revoke by name, then grant INSERT on exactly the
-- six columns the form sends. service_role keeps full access.

alter table public.muster_beta_signups
  add column scan_website_id bigint references muster.websites(id) on delete set null,
  add column scan_id         bigint references muster.scans(id) on delete set null,
  add column scan_queued_at  timestamptz,
  add column scan_error      text;

revoke all on public.muster_beta_signups from anon, authenticated;
grant insert (full_name, company_name, email, site_url, industry, marketing_consent)
  on public.muster_beta_signups to anon, authenticated;

create or replace function public.muster_beta_signup_queue_scan(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row        public.muster_beta_signups%rowtype;
  v_org        bigint;
  v_user       bigint;
  v_url        text;
  v_website_id bigint;
  v_result     jsonb;
  v_scan_id    bigint;
begin
  select * into v_row from public.muster_beta_signups where id = p_id;
  if v_row.id is null then
    raise exception 'beta signup % not found', p_id using errcode = 'P0002';
  end if;

  begin
    v_url := trim(v_row.site_url);
    v_org := muster.admin_sandbox_org();
    select min(id) into v_user from muster.users where role = 'super_admin';
    if v_user is null then
      raise exception 'no super_admin user exists to own the sandbox website';
    end if;

    select id into v_website_id
      from muster.websites
     where organization_id = v_org and lower(url) = lower(v_url)
     limit 1;

    if v_website_id is null then
      v_result := muster.do_add_website(v_org, v_row.company_name, v_url, 'production', 10080, v_user, 'manual');
      v_website_id := (v_result->>'website_id')::bigint;
      v_scan_id := (v_result->'first_scan'->>'scan_id')::bigint;
    else
      v_result := muster.do_request_scan(v_website_id, v_user, null, 'manual');
      v_scan_id := (v_result->>'scan_id')::bigint;
    end if;

    update public.muster_beta_signups
       set scan_website_id = v_website_id,
           scan_id = v_scan_id,
           scan_queued_at = now(),
           scan_error = null
     where id = p_id;
  exception when others then
    update public.muster_beta_signups
       set scan_error = left(sqlerrm, 500),
           scan_queued_at = null
     where id = p_id;
  end;
end;
$$;

revoke all on function public.muster_beta_signup_queue_scan(uuid) from public, anon, authenticated;
grant execute on function public.muster_beta_signup_queue_scan(uuid) to service_role;

create or replace function public.muster_beta_signup_queue_scan_trg()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.muster_beta_signup_queue_scan(new.id);
  return new;
end;
$$;

drop trigger if exists trg_muster_beta_signup_queue_scan on public.muster_beta_signups;
create trigger trg_muster_beta_signup_queue_scan
  after insert on public.muster_beta_signups
  for each row execute function public.muster_beta_signup_queue_scan_trg();

-- Backfill: every signup already in the table gets the scan it was promised.
select public.muster_beta_signup_queue_scan(id)
  from public.muster_beta_signups
 where scan_id is null and scan_error is null;

do $$
declare
  v_unqueued int;
  v_errored  int;
  v_anon_table int;
  v_anon_cols text;
begin
  select count(*) filter (where scan_id is null and scan_error is null),
         count(*) filter (where scan_error is not null)
    into v_unqueued, v_errored
    from public.muster_beta_signups;
  if v_unqueued <> 0 then
    raise exception 'backfill left % signup(s) with neither a scan_id nor a scan_error', v_unqueued;
  end if;
  if v_errored <> 0 then
    raise exception '% signup(s) failed to queue: %', v_errored,
      (select string_agg(email || ': ' || scan_error, '; ') from public.muster_beta_signups where scan_error is not null);
  end if;

  select count(*) into v_anon_table
    from information_schema.role_table_grants
   where table_schema = 'public' and table_name = 'muster_beta_signups' and grantee in ('anon','authenticated');
  if v_anon_table <> 0 then
    raise exception 'anon/authenticated still hold table-level privileges on muster_beta_signups';
  end if;

  select string_agg(distinct column_name, ',' order by column_name) into v_anon_cols
    from information_schema.role_column_grants
   where table_schema = 'public' and table_name = 'muster_beta_signups'
     and grantee = 'anon' and privilege_type = 'INSERT';
  if v_anon_cols is distinct from 'company_name,email,full_name,industry,marketing_consent,site_url' then
    raise exception 'anon insert columns are %, expected exactly the six form fields', v_anon_cols;
  end if;

  if not exists (select 1 from pg_trigger where tgname = 'trg_muster_beta_signup_queue_scan' and tgrelid = 'public.muster_beta_signups'::regclass) then
    raise exception 'trg_muster_beta_signup_queue_scan is missing';
  end if;

  raise notice 'beta signups now queue a sandbox scan; existing rows backfilled with no errors';
end $$;
