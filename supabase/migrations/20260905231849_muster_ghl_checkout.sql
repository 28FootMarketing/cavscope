-- GHL checkout wiring, phase 1 (sales-assisted): payment is collected inside
-- GHL (native invoicing/Stripe-connect), not a separate MUSTER-owned Stripe
-- account -- see the checkout-flow scoping conversation. Once a deal closes,
-- a GHL workflow's outbound Webhook action calls the new muster-ghl-webhook
-- Edge Function, which provisions the real tenant on the correct paid plan
-- instead of the trial state self-serve signups start in.
--
-- Everything here is reachable only by service_role (the Edge Function's own
-- client), never by anon/authenticated -- mirrors the existing
-- muster_engine_secret / muster_engine_ingest pattern used by muster-scan.

-- Which pricing stage (seed/fruit) a MUSTER or MUSTER Partner org locked in.
-- Flagged as a gap in the prior managed_by_org_id migration; this webhook is
-- the first real write path for it, so adding it here rather than leaving it
-- unrecorded on every org this flow provisions.
alter table muster.organizations
  add column if not exists commercial_stage varchar(10) check (commercial_stage in ('seed', 'fruit'));

-- Shared secret the GHL workflow's Webhook action must send back as the
-- x-muster-secret header. This is MUSTER's own generated secret, not a GHL
-- credential -- nothing about GHL's own API key/location id is needed for
-- this direction (GHL calling MUSTER). Writing muster_org_id back to the GHL
-- contact afterward would need that, and isn't implemented here.
--
-- The actual secret value is NOT committed here -- it was generated and
-- inserted directly via `select vault.create_secret(...)` as a one-off
-- operational statement (same reasoning as the earlier admin temp-password
-- reset: a live credential doesn't belong in permanent git history). If this
-- migration is ever replayed on a fresh project, that insert needs to be
-- re-run separately with a freshly generated value.

create or replace function public.muster_ghl_webhook_secret()
returns text language sql security definer set search_path = '' as $$
  select decrypted_secret from vault.decrypted_secrets where name = 'muster_ghl_webhook_secret' limit 1;
$$;
-- revoke from public alone is not enough here -- Supabase's default
-- privileges grant EXECUTE directly to anon/authenticated on new functions
-- in the public schema (that grant doesn't come through PUBLIC, so REVOKE
-- ... FROM PUBLIC never touches it). Confirmed this the hard way: the
-- security advisor flagged all three functions below as anon-executable
-- until anon/authenticated were revoked explicitly.
revoke all on function public.muster_ghl_webhook_secret() from public, anon, authenticated;
grant execute on function public.muster_ghl_webhook_secret() to service_role;

-- supabase-js has no direct "get auth user by email"; this lets the Edge
-- Function check whether the admin already has an account before deciding
-- whether to invite a new one or reuse the existing one.
create or replace function public.muster_find_auth_user_by_email(p_email text)
returns uuid language sql security definer set search_path = '' as $$
  select id from auth.users where lower(email) = lower(p_email) limit 1;
$$;
revoke all on function public.muster_find_auth_user_by_email(text) from public, anon, authenticated;
grant execute on function public.muster_find_auth_user_by_email(text) to service_role;

-- Full provisioning: creates/updates the muster.users row, runs the existing
-- self-serve tenant-creation path (muster.do_onboard -- same one used by the
-- real onboarding flow, reused rather than duplicated), then immediately
-- upgrades the resulting org off 'trial' onto the plan the customer actually
-- paid for. muster_admin_set_plan isn't reused here because it requires an
-- is_super_admin() session, which a service-role webhook call doesn't have --
-- this function's own service_role-only grant is the equivalent authorization.
create or replace function public.muster_ghl_provision(p jsonb, p_auth_user_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_user muster.users;
  v_tier text := p->>'tier';
  v_stage text := p->>'stage';
  v_plan varchar;
  v_result jsonb;
  v_org_id bigint;
begin
  v_plan := case v_tier
    when 'muster' then 'starter'
    when 'muster_partner' then 'pro'
    when 'muster_enterprise' then 'enterprise'
    else null
  end;
  if v_plan is null then
    raise exception 'unknown tier: % (expected muster, muster_partner, or muster_enterprise)', v_tier using errcode = '22023';
  end if;
  if v_stage is not null and v_stage not in ('seed', 'fruit') then
    raise exception 'stage must be seed or fruit' using errcode = '22023';
  end if;
  if coalesce(p->>'admin_email', '') = '' then
    raise exception 'admin_email is required' using errcode = '22023';
  end if;

  insert into muster.users (auth_user_id, name, email, login_method, role)
  values (p_auth_user_id, coalesce(nullif(p->>'admin_name', ''), 'Admin'), lower(p->>'admin_email'), 'email', 'user')
  on conflict (auth_user_id) do update set email = excluded.email
  returning * into v_user;

  v_result := muster.do_onboard(p, v_user.id);
  v_org_id := (v_result->'organization'->>'id')::bigint;

  update muster.organizations
  set plan = v_plan,
      website_limit = (select website_limit from muster.plans where plan = v_plan),
      commercial_stage = v_stage
  where id = v_org_id;

  insert into muster.activity_events (organization_id, entity_type, entity_id, action, detail, actor_id)
  values (v_org_id, 'organization', v_org_id, 'Provisioned via GHL checkout',
    format('tier=%s stage=%s ghl_contact_id=%s', v_tier, coalesce(v_stage, 'n/a'), coalesce(p->>'ghl_contact_id', 'n/a')), v_user.id);

  return muster.q_organization(v_org_id);
end;
$$;
revoke all on function public.muster_ghl_provision(jsonb, uuid) from public, anon, authenticated;
grant execute on function public.muster_ghl_provision(jsonb, uuid) to service_role;
