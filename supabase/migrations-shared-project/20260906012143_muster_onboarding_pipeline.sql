-- RETROACTIVE RECORD -- DEAD CODE, DO NOT WIRE UP WITHOUT RE-VERIFYING FIRST.
--
-- This was applied live to the shared project on 2026-09-06 (deployed
-- migration version 20260906012143) with no matching file committed to the
-- repo at the time -- discovered as repo/database drift during the
-- autonomy audit (.planning/autonomy/EVIDENCE-REGISTER.md FIND-004).
-- Written now for repo reproducibility, guarded to be a no-op on a database
-- that already has it.
--
-- This is a self-serve Stripe checkout path, independent of and never
-- reconciled against the GHL sales-assisted checkout path
-- (muster_ghl_checkout.sql / muster-ghl-webhook). As of this writing it is
-- verified DEAD:
--   1. No edge function named muster-stripe-webhook exists in this project,
--      and nothing in muster-scan/muster-agent/muster-ghl-webhook calls
--      muster.onboard_client.
--   2. Every row in muster.commercial_pricing has stripe_price_id = null,
--      so muster.onboard_client's own price lookup always raises
--      'no commercial_pricing row for stripe_price_id %' before it can do
--      anything else.
--   3. Even past that: this function inserts
--      organization_members.role = 'owner', but the live
--      organization_members_role_check constraint only permits
--      ('executive','risk_owner','control_owner','contributor','viewer').
--      This insert would fail with a check-violation. This function has
--      never been exercised end-to-end.
--
-- Who built this and why is not established by any evidence available to
-- the autonomy audit -- recorded as unknown, not guessed.
--
-- See .planning/autonomy/BLOCKERS-AND-DECISIONS.md B-1: do not finish this
-- path (or build muster-stripe-webhook, or backfill stripe_price_id) until
-- a decision is made on whether MUSTER wants GHL-only, Stripe-only, or
-- both checkout paths. If this path is chosen, the role bug above must be
-- fixed first.

alter table muster.commercial_pricing add column if not exists maps_to_plan character varying;

update muster.commercial_pricing set maps_to_plan = case
  when tier = 'muster' and stage = 'seed' then 'starter'
  when tier = 'muster' and stage = 'fruit' then 'pro'
  when tier = 'muster_partner' and stage = 'seed' then 'pro'
  when tier = 'muster_partner' and stage = 'fruit' then 'enterprise'
end
where maps_to_plan is null;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'commercial_pricing_maps_to_plan_fkey'
  ) then
    alter table muster.commercial_pricing
      add constraint commercial_pricing_maps_to_plan_fkey
      foreign key (maps_to_plan) references muster.plans(plan);
  end if;
end $$;

-- enforce one Stripe price per tier/stage once price IDs are backfilled
create unique index if not exists commercial_pricing_stripe_price_id_key
  on muster.commercial_pricing (stripe_price_id) where stripe_price_id is not null;

-- Idempotent onboarding RPC. Intended to be called by a muster-stripe-webhook
-- Edge Function (not built) AFTER it has created (or found) the Supabase
-- Auth user via supabase.auth.admin.inviteUserByEmail(). SECURITY DEFINER
-- so the edge function's service-role call can run it directly.
-- KNOWN BUG (see header): organization_members.role = 'owner' below violates
-- the live check constraint. Left as originally deployed for an accurate
-- historical record -- fix this before ever wiring a caller to it.
create or replace function muster.onboard_client(
  p_auth_user_id uuid,
  p_email character varying,
  p_name text,
  p_org_name character varying,
  p_stripe_price_id character varying,
  p_website_name character varying,
  p_website_url character varying,
  p_included_client_orgs integer default null
) returns table(organization_id bigint, website_id bigint, resolved_plan character varying)
language plpgsql
security definer
set search_path = muster, public
as $$
declare
  v_user_id bigint;
  v_plan character varying;
  v_website_limit integer;
  v_cadence integer;
  v_org_id bigint;
  v_site_id bigint;
begin
  select cp.maps_to_plan into v_plan
  from muster.commercial_pricing cp
  where cp.stripe_price_id = p_stripe_price_id;

  if v_plan is null then
    raise exception 'onboard_client: no commercial_pricing row for stripe_price_id %', p_stripe_price_id;
  end if;

  select pl.website_limit, pl.scan_cadence_min_minutes
  into v_website_limit, v_cadence
  from muster.plans pl where pl.plan = v_plan;

  -- partner tier: website_limit becomes "client orgs included", not sites on THIS org
  if p_included_client_orgs is not null then
    v_website_limit := p_included_client_orgs;
  end if;

  insert into muster.users (auth_user_id, name, email, login_method)
  values (p_auth_user_id, p_name, p_email, 'invite')
  on conflict (auth_user_id) do update set name = excluded.name, email = excluded.email
  returning id into v_user_id;

  insert into muster.organizations
    (name, plan, website_limit, onboarding_status, created_by_id, risk_owner_id, commercial_stage)
  values
    (p_org_name, v_plan, v_website_limit, 'provisioning', v_user_id, v_user_id,
     (select stage from muster.commercial_pricing where stripe_price_id = p_stripe_price_id))
  returning id into v_org_id;

  insert into muster.organization_members (organization_id, user_id, role)
  values (v_org_id, v_user_id, 'owner');

  insert into muster.websites (name, url, owner_id, organization_id)
  values (p_website_name, p_website_url, v_user_id, v_org_id)
  returning id into v_site_id;

  insert into muster.website_scan_settings (website_id, cadence_minutes, next_run_at)
  values (v_site_id, v_cadence, now());

  insert into muster.risk_appetites
    (organization_id, statement, critical_threshold, high_threshold, review_cadence, owner_id, next_review_at)
  values
    (v_org_id, 'Default risk appetite pending client review.', 1, 3, 'quarterly', v_user_id, now() + interval '30 days');

  update muster.organizations
  set onboarding_status = 'complete', onboarding_completed_at = now()
  where id = v_org_id;

  insert into muster.activity_events (organization_id, entity_type, entity_id, action, detail, actor_id)
  values (v_org_id, 'organization', v_org_id, 'onboarding_complete',
          'Auto-onboarded via Stripe checkout, price ' || p_stripe_price_id, v_user_id);

  return query select v_org_id, v_site_id, v_plan;
end;
$$;
-- Not revoked/granted to service_role here, matching the live deployed
-- state as found -- no grant to anon/authenticated exists (confirmed via
-- get_advisors: no anon/authenticated-executable finding for this
-- function), but no explicit service_role grant was found either, which is
-- consistent with "never wired to a caller."
