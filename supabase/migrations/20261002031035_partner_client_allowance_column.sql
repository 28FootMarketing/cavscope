-- Client organizations for the Partner tier (client_management_enabled).
--
-- Until now the Partner tier was sold with "5 or 10 client organizations" and nothing
-- created one: organizations.managed_by_org_id was set by no function. This adds the
-- real path. Design, and why:
--
--  * Partner status is organizations.partner_client_allowance (null = not a Partner).
--    The Stripe grant path records plan and stage but NOT the tier, so the database cannot
--    tell a Partner from an ordinary Pro buyer; guessing would hand the allowance to the
--    wrong people. A super admin sets it explicitly (cavscope_admin_set_partner_allowance).
--    Wiring the Stripe tier through to it is a separate, later change.
--  * Creating a client needs: executive on the Partner org (or super admin), the
--    client_management_enabled flag, an allowance, room under it, and a Partner that is not
--    itself a client (no chains). Past the allowance it REFUSES: "$39 per extra org" billing
--    is not built, and silently allowing extras would give them away.
--  * The client inherits the Partner's plan, website limit and commercial stage, and the
--    creating user becomes its executive, so every existing RLS rule and the tenant
--    switcher work unchanged. Country, region and timezone are inherited too.
--
-- The flag's enforcement is set here, in the same migration that reads it, per CLAUDE.md.

alter table cavscope.organizations add column if not exists partner_client_allowance integer;
alter table cavscope.organizations drop constraint if exists organizations_partner_allowance_check;
alter table cavscope.organizations add constraint organizations_partner_allowance_check
  check (partner_client_allowance is null or partner_client_allowance >= 0);
comment on column cavscope.organizations.partner_client_allowance is
  'Number of client organizations this Partner may create. NULL = not a Partner. Set only by cavscope_admin_set_partner_allowance.';

