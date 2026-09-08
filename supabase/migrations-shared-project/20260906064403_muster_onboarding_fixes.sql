-- Fixes to the guided-onboarding sequence (muster.onboarding_steps /
-- onboard_client / muster_onboarding_state / muster_onboarding_complete_step),
-- built directly against this Supabase project in a separate session and
-- reconciled into git here (see 20260908065000_muster_guided_onboarding.sql
-- for the reconstructed original). Found on review, before any client ever
-- reached step 3 or 4:
--
-- 1. SECURITY (live, exploitable): public.muster_mark_website_verified had
--    the default anon/authenticated EXECUTE grants Postgres hands out on
--    every new function, never revoked. It unconditionally sets
--    websites.verified_at with no ownership check, so any unauthenticated
--    caller could POST any website_id to it via PostgREST and fake-verify
--    a site they don't own -- completely bypassing the real HTTP
--    fetch-and-check-meta-tag step the muster-verify-site Edge Function
--    does before calling it. Locked to service_role only, matching how the
--    edge function actually calls it (via the service-role client).
-- 2. muster_onboarding_complete_step's 'risk_appetite' branch validated and
--    wrote review_cadence = 'semiannual', but muster.risk_appetites' own
--    check constraint only allows 'semi_annual' (with the underscore, same
--    spelling the tenant workspace's own risk-appetite editor already uses).
--    Choosing the semi-annual option at onboarding step 4 would pass the
--    function's validation and then fail on the table's check constraint.
-- 3. Same branch never checked high_threshold >= critical_threshold, which
--    muster.risk_appetites also enforces via check constraint -- so an
--    inverted pair (e.g. critical=5, high=2) surfaced as a raw constraint
--    violation instead of a clear validation error.

revoke all on function public.muster_mark_website_verified(bigint) from public, anon, authenticated;
grant execute on function public.muster_mark_website_verified(bigint) to service_role;
revoke all on function muster.mark_website_verified(bigint) from public, anon, authenticated;

-- muster_onboarding_state/complete_step aren't exploitable the same way --
-- both resolve the caller through muster.onboarding_caller()'s auth.uid()
-- check and no-op for a truly anonymous call -- but they carry the same
-- unrevoked default anon grant every other public.muster_* RPC in this repo
-- explicitly strips. Matching that convention here.
revoke all on function public.muster_onboarding_state() from public, anon;
grant execute on function public.muster_onboarding_state() to authenticated;
revoke all on function public.muster_onboarding_complete_step(character varying, jsonb) from public, anon;
grant execute on function public.muster_onboarding_complete_step(character varying, jsonb) to authenticated;

create or replace function public.muster_onboarding_complete_step(p_step_key character varying, p_payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'muster', 'public' as $function$
declare v_user bigint; v_org bigint; v_step muster.onboarding_steps; v_site bigint; v_prev_open integer;
begin
  select user_id, org_id into v_user, v_org from muster.onboarding_caller();
  if v_org is null then raise exception 'no onboarding in progress for this user'; end if;

  select * into v_step from muster.onboarding_steps where organization_id = v_org and step_key = p_step_key;
  if v_step.id is null then raise exception 'unknown step %', p_step_key; end if;
  if v_step.completed_at is not null then return public.muster_onboarding_state(); end if;

  select count(*) into v_prev_open from muster.onboarding_steps
  where organization_id = v_org and step_no < v_step.step_no and completed_at is null;
  if v_prev_open > 0 then raise exception 'step % is locked: % earlier step(s) incomplete', p_step_key, v_prev_open; end if;

  select id into v_site from muster.websites where organization_id = v_org order by id limit 1;

  case p_step_key
    when 'account' then
      if coalesce((p_payload->>'password_set')::boolean, false) is not true then raise exception 'password must be set first'; end if;

    when 'organization' then
      if length(coalesce(p_payload->>'name','')) < 2 or length(coalesce(p_payload->>'industry','')) < 2
         or length(coalesce(p_payload->>'country_code','')) <> 2 or length(coalesce(p_payload->>'timezone','')) < 3 then
        raise exception 'organization requires name, industry, country_code (2 letters), timezone'; end if;
      update muster.organizations set name = p_payload->>'name', industry = p_payload->>'industry',
        country_code = upper(p_payload->>'country_code'), timezone = p_payload->>'timezone' where id = v_org;

    when 'website' then
      if (select verified_at from muster.websites where id = v_site) is null then
        raise exception 'website ownership not verified yet: add the meta tag then click Verify'; end if;
      update muster.website_scan_settings set enabled = true where website_id = v_site;

    when 'risk_appetite' then
      if length(coalesce(p_payload->>'statement','')) < 40 then raise exception 'risk appetite statement must be at least 40 characters'; end if;
      if coalesce((p_payload->>'critical_threshold')::int, -1) < 0 or coalesce((p_payload->>'high_threshold')::int, -1) < 0 then
        raise exception 'thresholds must be >= 0'; end if;
      if (p_payload->>'high_threshold')::int < (p_payload->>'critical_threshold')::int then
        raise exception 'high threshold must be >= critical threshold'; end if;
      if p_payload->>'review_cadence' not in ('monthly','quarterly','semi_annual','annual') then raise exception 'review_cadence invalid'; end if;
      update muster.risk_appetites set statement = p_payload->>'statement',
        critical_threshold = (p_payload->>'critical_threshold')::int, high_threshold = (p_payload->>'high_threshold')::int,
        review_cadence = p_payload->>'review_cadence', owner_id = v_user, updated_at = now(),
        next_review_at = now() + case p_payload->>'review_cadence' when 'monthly' then interval '1 month'
          when 'quarterly' then interval '3 months' when 'semi_annual' then interval '6 months' else interval '12 months' end
      where organization_id = v_org;

    when 'team' then
      if jsonb_array_length(coalesce(p_payload->'sitrep_recipients','[]'::jsonb)) < 1 then raise exception 'at least one SITREP recipient email required'; end if;
      update muster.organizations set risk_owner_id = v_user,
        sitrep_recipients = array(select jsonb_array_elements_text(p_payload->'sitrep_recipients')) where id = v_org;
      insert into muster.pending_invites (organization_id, email, role, invited_by_id)
      select v_org, e, 'member', v_user from jsonb_array_elements_text(coalesce(p_payload->'invites','[]'::jsonb)) e
      on conflict do nothing;

    when 'first_scan' then
      if not exists (select 1 from muster.scans where website_id = v_site and finished_at is not null) then
        if not exists (select 1 from muster.scans where website_id = v_site and finished_at is null) then
          insert into muster.scans (organization_id, website_id, trigger, status, requested_by_id, target_url, queued_at)
          select v_org, v_site, 'onboarding', 'queued', v_user, w.url, now() from muster.websites w where w.id = v_site;
          update muster.website_scan_settings set next_run_at = now() where website_id = v_site;
        end if;
        raise exception 'first scan queued; it completes automatically when the scan finishes';
      end if;

    when 'sitrep' then
      if coalesce((p_payload->>'acknowledged')::boolean, false) is not true then raise exception 'confirm you have read the SITREP'; end if;
      update muster.organizations set onboarding_status = 'complete', onboarding_completed_at = now() where id = v_org;
      insert into muster.activity_events (organization_id, entity_type, entity_id, action, detail, actor_id)
      values (v_org, 'organization', v_org, 'onboarding_complete', 'All 7 guided steps completed', v_user);
    else raise exception 'unhandled step %', p_step_key;
  end case;

  update muster.onboarding_steps set completed_at = now(), completed_by_id = v_user, payload = p_payload where id = v_step.id;
  return public.muster_onboarding_state();
end $function$;
