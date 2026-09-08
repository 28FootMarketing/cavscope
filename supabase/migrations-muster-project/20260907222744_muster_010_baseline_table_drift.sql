-- Columns and constraints added to the 16 baseline tables AFTER the original
-- sentinel schema, recovered by diffing this project against the live source.
--
-- muster_003 built those tables from ledger version 20260902025934, which is
-- their shape on day one. Everything since -- plans, onboarding state, partner
-- org management, the admin sandbox flag, alert opt-out, SITREP recipients,
-- domain verification -- arrived as ALTER TABLE in later migrations. The
-- structural diff caught the gap precisely: 16 columns, 4 checks, 3 FKs.
--
-- Worth noting what these are, because they are not cosmetic:
--   organizations.plan / website_limit      the entitlement gate every RPC reads
--   organizations.onboarding_status         the server-side onboarding state machine
--   organizations.is_admin_sandbox          keeps ad-hoc admin URL scans out of real tenants
--   organizations.managed_by_org_id         partner -> client org hierarchy, with a
--                                           self-reference guard so an org cannot manage itself
--   organizations.critical_alerts_enabled   per-org alert opt-out
--   websites.verification_token/verified_at domain ownership proof

alter table muster.activity_events add column if not exists agent_id bigint;
alter table muster.organizations add column if not exists plan character varying(16) default 'trial'::character varying not null;
alter table muster.organizations add column if not exists country_code character(2);
alter table muster.organizations add column if not exists region_code character varying(8);
alter table muster.organizations add column if not exists timezone character varying(64) default 'America/New_York'::character varying not null;
alter table muster.organizations add column if not exists website_limit integer default 1 not null;
alter table muster.organizations add column if not exists onboarding_status character varying(16) default 'started'::character varying not null;
alter table muster.organizations add column if not exists onboarding_completed_at timestamp with time zone;
alter table muster.organizations add column if not exists created_by_id bigint;
alter table muster.organizations add column if not exists managed_by_org_id bigint;
alter table muster.organizations add column if not exists commercial_stage character varying(10);
alter table muster.organizations add column if not exists critical_alerts_enabled boolean default true not null;
alter table muster.organizations add column if not exists is_admin_sandbox boolean default false not null;
alter table muster.organizations add column if not exists sitrep_recipients text[];
alter table muster.websites add column if not exists verification_token character varying;
alter table muster.websites add column if not exists verified_at timestamp with time zone;

alter table muster.organizations add constraint organizations_commercial_stage_check check (((commercial_stage)::text = any ((array['seed'::character varying, 'fruit'::character varying])::text[])));
alter table muster.organizations add constraint organizations_not_self_managed_check check (((managed_by_org_id is null) or (managed_by_org_id <> id)));
alter table muster.organizations add constraint organizations_onboarding_check check (((onboarding_status)::text = any ((array['started'::character varying, 'profile'::character varying, 'website'::character varying, 'first_scan'::character varying, 'complete'::character varying])::text[])));
alter table muster.organizations add constraint organizations_plan_check check (((plan)::text = any ((array['trial'::character varying, 'starter'::character varying, 'pro'::character varying, 'enterprise'::character varying, 'internal'::character varying])::text[])));

alter table muster.activity_events add constraint activity_events_agent_fk foreign key (agent_id) references muster.agents(id);
alter table muster.organizations add constraint organizations_created_by_id_fkey foreign key (created_by_id) references muster.users(id);
alter table muster.organizations add constraint organizations_managed_by_org_id_fkey foreign key (managed_by_org_id) references muster.organizations(id) on delete restrict;
