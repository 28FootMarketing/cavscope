-- Tenant workspace gap fixes, found by a full RPC-vs-UI audit of app.html.
-- The underlying muster.* tables (risks, remediation_actions, risk_appetites,
-- pending_invites) already had full member-read / can_write_org RLS in place
-- since the original tenancy migration -- what was missing is the thin
-- public.muster_* RPC shim PostgREST needs to reach them at all (PostgREST
-- only exposes the public schema, per every other muster_* RPC in this
-- file), plus a way for a tenant to control their own org's critical-finding
-- alert opt-in (organizations.critical_alerts_enabled, added in PRD-001,
-- which had a super-admin view but no tenant-facing read/write path).

-- Real risk register (auto-populated by muster.autotriage(), previously
-- invisible -- the UI's "Risk Register" tab was rendering a client-side
-- fake built from raw findings, not this table).
create or replace function public.muster_risks(p_website_id bigint)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not muster.is_org_member(muster.website_org(p_website_id)) then raise exception 'forbidden' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(to_jsonb(r) || jsonb_build_object(
      'owner_name', (select name from muster.users where id = r.owner_id),
      'remediation_actions', (
        select coalesce(jsonb_agg(to_jsonb(a) || jsonb_build_object('owner_name', (select name from muster.users where id = a.owner_id)) order by a.due_date nulls last), '[]'::jsonb)
        from muster.remediation_actions a where a.risk_id = r.id))
      order by case r.severity when 'critical' then 0 when 'high' then 1 when 'medium' then 2 else 3 end, r.target_date nulls last)
    from muster.risks r where r.website_id = p_website_id and r.status <> 'closed'
  ), '[]'::jsonb);
end;
$$;
revoke all on function public.muster_risks(bigint) from public, anon;
grant execute on function public.muster_risks(bigint) to authenticated;

create or replace function public.muster_risk_appetite(p_organization_id bigint)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not muster.is_org_member(p_organization_id) then raise exception 'forbidden' using errcode = '42501'; end if;
  return (select to_jsonb(ra) from muster.risk_appetites ra where ra.organization_id = p_organization_id);
end;
$$;
revoke all on function public.muster_risk_appetite(bigint) from public, anon;
grant execute on function public.muster_risk_appetite(bigint) to authenticated;

create or replace function public.muster_save_risk_appetite(p_organization_id bigint, p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_uid bigint := muster.current_user_id();
begin
  if not muster.can_write_org(p_organization_id) then raise exception 'forbidden' using errcode = '42501'; end if;
  update muster.risk_appetites set
    statement = coalesce(nullif(p->>'statement', ''), statement),
    critical_threshold = coalesce((p->>'critical_threshold')::int, critical_threshold),
    high_threshold = coalesce((p->>'high_threshold')::int, high_threshold),
    review_cadence = coalesce(nullif(p->>'review_cadence', ''), review_cadence),
    next_review_at = coalesce((p->>'next_review_at')::timestamptz, next_review_at),
    updated_at = now()
  where organization_id = p_organization_id;
  if not found then
    insert into muster.risk_appetites (organization_id, statement, critical_threshold, high_threshold, review_cadence, next_review_at, owner_id)
    values (p_organization_id, coalesce(p->>'statement', 'Risk appetite not yet defined.'),
      coalesce((p->>'critical_threshold')::int, 0), coalesce((p->>'high_threshold')::int, 2),
      coalesce(nullif(p->>'review_cadence', ''), 'quarterly'),
      coalesce((p->>'next_review_at')::timestamptz, now() + interval '90 days'), v_uid);
  end if;
  return (select to_jsonb(ra) from muster.risk_appetites ra where ra.organization_id = p_organization_id);
end;
$$;
revoke all on function public.muster_save_risk_appetite(bigint, jsonb) from public, anon;
grant execute on function public.muster_save_risk_appetite(bigint, jsonb) to authenticated;

-- Tenant self-service control for the critical-finding alert opt-out
-- (organizations.critical_alerts_enabled). The column and the super-admin
-- view of it already existed (PRD-001); this is the missing tenant-facing
-- write path. Reads need no new RPC -- the column already rides along in
-- every muster_my_workspace()/q_organization() response as part of
-- to_jsonb(o).
create or replace function public.muster_set_org_alert_preference(p_organization_id bigint, p_enabled boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if not muster.can_write_org(p_organization_id) then raise exception 'forbidden' using errcode = '42501'; end if;
  update muster.organizations set critical_alerts_enabled = p_enabled where id = p_organization_id;
  return jsonb_build_object('organization_id', p_organization_id, 'critical_alerts_enabled', p_enabled);
end;
$$;
revoke all on function public.muster_set_org_alert_preference(bigint, boolean) from public, anon;
grant execute on function public.muster_set_org_alert_preference(bigint, boolean) to authenticated;

-- Pending invites list, for the team management panel -- RLS on
-- pending_invites already permits any org member to read their org's rows;
-- this is just the PostgREST-reachable door.
create or replace function public.muster_pending_invites(p_organization_id bigint)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not muster.is_org_member(p_organization_id) then raise exception 'forbidden' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'email', i.email, 'role', i.role, 'created_at', i.created_at,
    'invited_by', (select name from muster.users where id = i.invited_by_id)) order by i.created_at desc)
    from muster.pending_invites i where i.organization_id = p_organization_id and i.claimed_at is null), '[]'::jsonb);
end;
$$;
revoke all on function public.muster_pending_invites(bigint) from public, anon;
grant execute on function public.muster_pending_invites(bigint) to authenticated;
