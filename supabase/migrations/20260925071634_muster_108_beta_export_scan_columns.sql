-- muster_108: one engine RPC so muster-beta-export can report each signup's
-- scan alongside the signup itself.
--
-- Migration 107 made a beta signup queue a sandbox scan and stored scan_id on
-- the row, but the export reads public.muster_beta_signups over PostgREST and
-- the scan lives in muster.scans, a schema PostgREST does not expose. The
-- posture score, band and open-finding counts are already on
-- muster.scans.summary (written by muster.engine_ingest), so this is a join,
-- not a computation, and the numbers are the ones the SITREP for that scan
-- was generated from.
--
-- Engine RPC rules apply: SECURITY DEFINER, empty search_path, and REVOKE
-- from anon and authenticated BY NAME -- Supabase's default privileges grant
-- EXECUTE on every new public function to both, and `revoke ... from public`
-- does not undo that. Only service_role may call it; the export function
-- holds that key. The signup list carries names, emails and site URLs, which
-- is why the ACL is asserted below rather than assumed.

create or replace function public.muster_engine_beta_export()
returns table (
  id               uuid,
  full_name        text,
  company_name     text,
  industry         text,
  email            text,
  site_url         text,
  marketing_consent boolean,
  status           text,
  created_at       timestamptz,
  scan_id          bigint,
  scan_queued_at   timestamptz,
  scan_status      text,
  scan_finished_at timestamptz,
  posture_score    integer,
  posture_band     text,
  open_critical    integer,
  open_high        integer,
  open_medium      integer,
  open_low         integer,
  open_info        integer,
  scan_error       text
)
language sql
security definer
set search_path = ''
stable
as $$
  select
    b.id,
    b.full_name,
    b.company_name,
    b.industry,
    b.email,
    b.site_url,
    b.marketing_consent,
    b.status,
    b.created_at,
    b.scan_id,
    b.scan_queued_at,
    s.status::text                                   as scan_status,
    s.finished_at                                    as scan_finished_at,
    (s.summary ->> 'posture_score')::integer         as posture_score,
    s.summary ->> 'posture_band'                     as posture_band,
    coalesce((s.summary -> 'open_by_severity' ->> 'critical')::integer, 0) as open_critical,
    coalesce((s.summary -> 'open_by_severity' ->> 'high')::integer, 0)     as open_high,
    coalesce((s.summary -> 'open_by_severity' ->> 'medium')::integer, 0)   as open_medium,
    coalesce((s.summary -> 'open_by_severity' ->> 'low')::integer, 0)      as open_low,
    coalesce((s.summary -> 'open_by_severity' ->> 'info')::integer, 0)     as open_info,
    b.scan_error
  from public.muster_beta_signups b
  left join muster.scans s on s.id = b.scan_id
  order by b.created_at desc;
$$;

revoke all on function public.muster_engine_beta_export() from public;
revoke all on function public.muster_engine_beta_export() from anon, authenticated;
grant execute on function public.muster_engine_beta_export() to service_role;

do $$
begin
  if has_function_privilege('anon', 'public.muster_engine_beta_export()', 'execute') then
    raise exception 'muster_engine_beta_export is executable by anon';
  end if;
  if has_function_privilege('authenticated', 'public.muster_engine_beta_export()', 'execute') then
    raise exception 'muster_engine_beta_export is executable by authenticated';
  end if;
  if not has_function_privilege('service_role', 'public.muster_engine_beta_export()', 'execute') then
    raise exception 'muster_engine_beta_export is not executable by service_role';
  end if;
  -- Every signup row must come back exactly once, scan or no scan.
  if (select count(*) from public.muster_engine_beta_export())
     <> (select count(*) from public.muster_beta_signups) then
    raise exception 'muster_engine_beta_export row count does not match muster_beta_signups';
  end if;
end $$;
