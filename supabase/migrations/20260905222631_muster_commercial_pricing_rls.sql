-- commercial_pricing was created without RLS in the prior migration -- every
-- other reference/catalog table in this schema (plans, scan_rules,
-- feature_flags) has RLS enabled with a read-only "muster_catalog_select"
-- policy for authenticated users. Matching that established pattern here.
alter table muster.commercial_pricing enable row level security;

create policy muster_catalog_select on muster.commercial_pricing
  for select
  to authenticated
  using (true);
