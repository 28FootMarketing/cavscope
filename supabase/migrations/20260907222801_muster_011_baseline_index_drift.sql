-- The last two indexes the structural diff flagged, both on organizations and
-- both partial with real meaning:
--
--   muster_organizations_admin_sandbox_uq  unique on is_admin_sandbox WHERE
--     is_admin_sandbox -- i.e. at most ONE admin sandbox org can exist in the
--     whole project. That is what keeps ad-hoc admin URL scans landing in a
--     single internal org instead of leaking into a real tenant's risk register.
--
--   organizations_managed_by_org_id_idx    partial on the partner -> client
--     hierarchy, indexing only rows that are actually managed.

create unique index muster_organizations_admin_sandbox_uq on muster.organizations using btree (is_admin_sandbox) where is_admin_sandbox;
create index organizations_managed_by_org_id_idx on muster.organizations using btree (managed_by_org_id) where (managed_by_org_id is not null);
