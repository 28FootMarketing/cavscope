-- Adds the one schema primitive the MUSTER Partner billing model (5/10
-- included client organizations, $39/$49 per additional) depends on:
-- knowing which client organizations belong to which Partner account.
-- Nothing in muster.organizations recorded this relationship before now.
--
-- Flat hierarchy assumed (a Partner manages client orgs directly; a client
-- org cannot itself be a Partner managing further orgs). Nothing in the
-- current app creates client orgs yet, so there is no existing code path
-- that could have created a chain -- not enforced with a trigger here since
-- there's no real scenario to guard against yet. Revisit if/when the actual
-- "add client organization" feature is built.
--
-- Does NOT touch RLS. muster_org_select already scopes visibility to
-- muster.is_org_member(id) -- this column alone does not let a Partner's
-- users see their client orgs' data. Partner-to-client visibility (the
-- "Partner dashboard" / client_management_enabled entitlement) is a
-- separate, larger feature: it needs its own access-control decision, not
-- a side effect of adding this column.
--
-- Also not addressed here: which pricing stage (seed/fruit) a given
-- Partner org locked in. That's needed to compute a dollar overage against
-- muster.commercial_pricing.included_client_orgs and isn't tracked
-- anywhere on organizations yet -- a separate follow-up.

alter table muster.organizations
  add column if not exists managed_by_org_id bigint references muster.organizations(id) on delete restrict;

alter table muster.organizations drop constraint if exists organizations_not_self_managed_check;
alter table muster.organizations add constraint organizations_not_self_managed_check
  check (managed_by_org_id is null or managed_by_org_id <> id);

create index if not exists organizations_managed_by_org_id_idx
  on muster.organizations (managed_by_org_id)
  where managed_by_org_id is not null;

-- The org-count query the Partner overage cron will need. Counts every
-- client org currently pointing at the given partner -- there is no
-- soft-delete/status concept on organizations yet, so "active" here means
-- "the row exists." Revisit if a client org can ever be paused/archived
-- without being deleted outright.
create or replace function muster.count_managed_orgs(p_partner_org_id bigint)
returns integer language sql stable security definer set search_path = '' as $$
  select count(*)::integer from muster.organizations where managed_by_org_id = p_partner_org_id;
$$;
