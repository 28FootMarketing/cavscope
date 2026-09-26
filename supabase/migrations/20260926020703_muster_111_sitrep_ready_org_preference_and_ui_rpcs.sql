-- Course-correction on muster_110's gating mechanism, plus the two RPCs the
-- workspace UI needs to actually wire this up.
--
-- muster_110 gated the sitrep_ready enqueue behind a NEW feature flag
-- (sitrep_ready_email), the fastest safe-by-default gate to ship alongside
-- the SQL. But muster.feature_flag_overrides is writable only from the
-- super-admin console -- every muster_admin_* write RPC checks
-- muster.is_super_admin() itself, and RLS backs that up (policy
-- muster_flag_overrides_write, using (muster.is_super_admin())). There is no
-- code path for an ordinary executive to flip an override on their own org's
-- flag. That makes "enable per org" from muster_110's own header a lie an
-- ordinary tenant cannot act on -- only a super admin manually inserting a
-- row could, which is not "wired to a page" by any reading of the phrase.
--
-- The sibling category already has the right shape: critical_alerts_enabled
-- is a plain column on muster.organizations, flipped by an executive/
-- contributor+ from their own workspace settings via
-- muster_set_org_alert_preference (muster.can_write_org -- see muster_014's
-- autotriage() and muster_019's RPC). sitrep_ready gets the same shape:
-- a column, not a flag override, because the flag layer already has a job
-- here -- email_alerts still gates the outbox CLAIM for every category
-- (unchanged) -- and stacking a second, admin-only flag underneath a
-- category-specific preference just duplicates that job somewhere a tenant
-- cannot reach.
--
-- So: retire the flag, add the column, and ship the two RPCs
-- (muster_set_sitrep_alert_preference, muster_set_sitrep_recipients) that let
-- an executive/contributor+ actually use it from app.html. Nothing depends on
-- the sitrep_ready_email flag outside this same feature (it shipped inactive,
-- has never been overridden -- verified: zero rows in feature_flag_overrides
-- for this key), so retiring it cleanly is safe.

delete from muster.feature_flag_overrides where flag_key = 'sitrep_ready_email';
delete from muster.feature_flags where key = 'sitrep_ready_email';

alter table muster.organizations
  add column if not exists sitrep_ready_alerts_enabled boolean default false not null;
comment on column muster.organizations.sitrep_ready_alerts_enabled is
  'Per-org opt-in for the sitrep_ready email (muster_engine_sitrep), mirroring critical_alerts_enabled. Defaults false, unlike critical_alerts_enabled''s true: scans default to a daily cadence and this shipped with no prior workspace-settings toggle, so opt-in avoids emailing every existing org daily the moment it ships. Set via muster_set_sitrep_alert_preference.';

CREATE OR REPLACE FUNCTION public.muster_engine_sitrep(p_scan_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_id bigint;
  v_org bigint;
  v_website_id bigint;
  v_website_name varchar;
  v_recipients text[];
  v_sitrep muster.sitreps%rowtype;
  v_org_row muster.organizations%rowtype;
begin
  select organization_id, website_id into v_org, v_website_id from muster.scans where id = p_scan_id;
  if not muster.has_flag(v_org, 'sitrep_generation') then
    return jsonb_build_object('skipped', true, 'reason', 'sitrep_generation flag off');
  end if;
  v_id := muster.generate_sitrep(p_scan_id);
  select * into v_sitrep from muster.sitreps where id = v_id;

  select * into v_org_row from muster.organizations where id = v_org;
  if v_org_row.sitrep_ready_alerts_enabled then
    v_recipients := v_org_row.sitrep_recipients;
    if v_recipients is null or array_length(v_recipients, 1) is null then
      select coalesce(array_agg(distinct u.email), '{}')
        into v_recipients
        from muster.organization_members om
        join muster.users u on u.id = om.user_id
        where om.organization_id = v_org and om.role in ('executive','risk_owner');
    end if;
    select w.name into v_website_name from muster.websites w where w.id = v_website_id;
    if array_length(v_recipients, 1) > 0 then
      insert into muster.notification_outbox
        (organization_id, category, entity_type, entity_id, severity, subject, body_text, recipient_emails)
      values (
        v_org, 'sitrep_ready', 'sitrep', v_id, 'info',
        format('[CavScope] SITREP ready: %s (%s)', v_website_name, v_sitrep.posture_band),
        format(E'A new SITREP is ready for %s.\n\nPosture: %s (%s/100)\n\n%s\n\nSign in to your CavScope workspace to view the full report.\n',
          v_website_name, v_sitrep.posture_band, v_sitrep.posture_score, v_sitrep.headline),
        v_recipients
      )
      on conflict (entity_type, entity_id, category) do nothing;
    else
      insert into muster.activity_events (organization_id, entity_type, entity_id, action, detail)
      values (v_org, 'sitrep', v_id, 'alert_skipped_no_recipient',
        'sitrep_ready_alerts_enabled is on but no sitrep_recipients set and no executive/risk_owner member found');
    end if;
  end if;

  return jsonb_build_object('sitrep_id', v_id, 'headline', v_sitrep.headline, 'posture_score', v_sitrep.posture_score, 'posture_band', v_sitrep.posture_band);
end;
$function$
;

-- Tenant self-service toggle, byte-for-byte the same shape as
-- muster_set_org_alert_preference (muster_019.sql:957-969).
CREATE OR REPLACE FUNCTION public.muster_set_sitrep_alert_preference(p_organization_id bigint, p_enabled boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if not muster.can_write_org(p_organization_id) then raise exception 'forbidden' using errcode = '42501'; end if;
  update muster.organizations set sitrep_ready_alerts_enabled = p_enabled where id = p_organization_id;
  return jsonb_build_object('organization_id', p_organization_id, 'sitrep_ready_alerts_enabled', p_enabled);
end;
$function$
;
revoke all on function public.muster_set_sitrep_alert_preference(bigint, boolean) from public, anon;
grant execute on function public.muster_set_sitrep_alert_preference(bigint, boolean) to authenticated, service_role;

-- Recipients, editable after onboarding. muster_onboarding_complete_step's
-- 'team' step (muster_020.sql:501-503) is the only existing writer, requires
-- >=1 email, and never runs again after onboarding completes. This is the
-- ongoing settings path, and unlike onboarding an EMPTY list is valid here:
-- muster_engine_sitrep already falls back to executive/risk_owner members
-- when sitrep_recipients is empty, so clearing the list is "use that default"
-- rather than an error state.
CREATE OR REPLACE FUNCTION public.muster_set_sitrep_recipients(p_organization_id bigint, p_emails jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_emails text[];
  v_email text;
begin
  if not muster.can_write_org(p_organization_id) then raise exception 'forbidden' using errcode = '42501'; end if;
  if jsonb_typeof(p_emails) <> 'array' then raise exception 'p_emails must be a JSON array' using errcode = '22023'; end if;

  select coalesce(array_agg(distinct lower(trim(e))) filter (where trim(e) <> ''), '{}'::text[])
    into v_emails
    from jsonb_array_elements_text(p_emails) e;

  foreach v_email in array v_emails loop
    if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
      raise exception 'invalid email: %', v_email using errcode = '22023';
    end if;
  end loop;

  update muster.organizations set sitrep_recipients = v_emails where id = p_organization_id;
  return jsonb_build_object('organization_id', p_organization_id, 'sitrep_recipients', to_jsonb(v_emails));
end;
$function$
;
revoke all on function public.muster_set_sitrep_recipients(bigint, jsonb) from public, anon;
grant execute on function public.muster_set_sitrep_recipients(bigint, jsonb) to authenticated, service_role;
