-- Baseline recovered from the source project's migration ledger, versions
-- 20260902025934 (sentinel_schema) + 20260903095155 (rename to muster),
-- collapsed into one and emitted already named `muster`.
--
-- WHY THIS EXISTS: supabase/migrations/ in the muster repo cannot build from an
-- empty database. Its first file, 20260904034922_muster_phase1_scan_engine.sql,
-- opens with
--     alter function muster.touch_updated_at() set search_path = ...
-- which assumes objects created by two pre-repo migrations that the repo's own
-- README deliberately excludes (they renamed a `sentinel` schema that a fresh
-- project does not have). Fixing migration ORDER in PR #46 did not make the
-- repo self-sufficient; moving to this project is what exposed that.
--
-- Creating `sentinel` here only to rename it would be theatre, so the rename is
-- pre-applied. Everything else is verbatim from the ledger.

create schema if not exists muster;

create table muster.users (
  id             bigserial primary key not null,
  auth_user_id   uuid not null,
  name           text,
  email          varchar(320),
  login_method   varchar(64),
  role           varchar(16) default 'user' not null,
  created_at     timestamptz default now() not null,
  updated_at     timestamptz default now() not null,
  last_signed_in timestamptz default now() not null,
  constraint users_auth_user_id_unique unique (auth_user_id)
);

create table muster.organizations (
  id            bigserial primary key not null,
  name          varchar(160) not null,
  industry      varchar(120),
  risk_owner_id bigint not null,
  created_at    timestamptz default now() not null,
  updated_at    timestamptz default now() not null
);

create table muster.websites (
  id              bigserial primary key not null,
  name            varchar(160) not null,
  url             varchar(512) not null,
  environment     varchar(16) default 'production' not null,
  owner_id        bigint not null,
  organization_id bigint,
  created_at      timestamptz default now() not null,
  updated_at      timestamptz default now() not null
);

create table muster.organization_members (
  id              bigserial primary key not null,
  organization_id bigint not null,
  user_id         bigint not null,
  role            varchar(32) default 'contributor' not null,
  created_at      timestamptz default now() not null
);

create table muster.controls (
  id             bigserial primary key not null,
  website_id     bigint not null,
  framework      varchar(16) not null,
  reference      varchar(80) not null,
  title          varchar(240) not null,
  description    text,
  assessment     varchar(16) default 'not_assessed' not null,
  owner_id       bigint,
  next_review_at timestamptz,
  created_at     timestamptz default now() not null,
  updated_at     timestamptz default now() not null
);

create table muster.control_tests (
  id                      bigserial primary key not null,
  control_id              bigint not null,
  period_start            timestamptz not null,
  period_end              timestamptz not null,
  test_status             varchar(24) default 'planned' not null,
  operating_effectiveness varchar(24) default 'not_tested' not null,
  tester_id               bigint,
  reviewer_id             bigint,
  findings                text,
  evidence_summary        text,
  tested_at               timestamptz,
  reviewed_at             timestamptz,
  created_at              timestamptz default now() not null,
  updated_at              timestamptz default now() not null
);

create table muster.risks (
  id                  bigserial primary key not null,
  website_id          bigint not null,
  title               varchar(240) not null,
  description         text,
  category            varchar(32) not null,
  source              varchar(32) default 'manual_review' not null,
  escalation_context  text,
  severity            varchar(16) not null,
  status              varchar(16) default 'open' not null,
  inherent_score      integer default 0 not null,
  residual_score      integer default 0 not null,
  treatment           varchar(16) default 'mitigate' not null,
  treatment_plan      text,
  owner_id            bigint,
  target_date         timestamptz,
  identified_at       timestamptz default now() not null,
  created_at          timestamptz default now() not null,
  updated_at          timestamptz default now() not null
);

create table muster.evidence (
  id             bigserial primary key not null,
  website_id     bigint not null,
  title          varchar(240) not null,
  description    text,
  evidence_type  varchar(16) not null,
  review_state   varchar(16) default 'pending' not null,
  source_url     varchar(1024),
  owner_id       bigint,
  reviewed_by_id bigint,
  reviewed_at    timestamptz,
  audit_context  text,
  period_end     timestamptz,
  created_at     timestamptz default now() not null,
  updated_at     timestamptz default now() not null
);

create table muster.evidence_links (
  id          bigserial primary key not null,
  evidence_id bigint not null,
  risk_id     bigint,
  control_id  bigint,
  created_at  timestamptz default now() not null
);

create table muster.remediation_actions (
  id                 bigserial primary key not null,
  risk_id            bigint not null,
  control_id         bigint,
  title              varchar(240) not null,
  description        text,
  status             varchar(16) default 'not_started' not null,
  progress           integer default 0 not null,
  owner_id           bigint,
  due_date           timestamptz,
  status_update      text,
  escalation_status  varchar(16) default 'none' not null,
  escalation_context text,
  escalated_at       timestamptz,
  verified_at        timestamptz,
  created_at         timestamptz default now() not null,
  updated_at         timestamptz default now() not null
);

create table muster.remediation_milestones (
  id                 bigserial primary key not null,
  remediation_id     bigint not null,
  title              varchar(240) not null,
  status             varchar(16) default 'not_started' not null,
  owner_id           bigint,
  due_date           timestamptz,
  completed_at       timestamptz,
  validation_notes   text,
  escalation_status  varchar(16) default 'none' not null,
  escalation_context text,
  escalated_at       timestamptz,
  validated_by_id    bigint,
  created_at         timestamptz default now() not null,
  updated_at         timestamptz default now() not null
);

create table muster.risk_appetites (
  id                 bigserial primary key not null,
  organization_id    bigint not null,
  statement          text not null,
  critical_threshold integer default 0 not null,
  high_threshold     integer default 2 not null,
  review_cadence     varchar(16) default 'quarterly' not null,
  next_review_at     timestamptz,
  owner_id           bigint,
  updated_at         timestamptz default now() not null
);

create table muster.risk_control_mappings (
  id           bigserial primary key not null,
  risk_id      bigint not null,
  control_id   bigint not null,
  relationship varchar(16) default 'prevent' not null,
  created_at   timestamptz default now() not null
);

create table muster.risk_exceptions (
  id             bigserial primary key not null,
  risk_id        bigint not null,
  title          varchar(240) not null,
  rationale      text not null,
  exception_type varchar(32) not null,
  status         varchar(16) default 'requested' not null,
  owner_id       bigint,
  approver_id    bigint,
  expires_at     timestamptz,
  decision_at    timestamptz,
  created_at     timestamptz default now() not null,
  updated_at     timestamptz default now() not null
);

create table muster.strategic_objectives (
  id              bigserial primary key not null,
  organization_id bigint not null,
  title           varchar(240) not null,
  description     text,
  owner_id        bigint,
  status          varchar(16) default 'on_track' not null,
  target_date     timestamptz,
  created_at      timestamptz default now() not null,
  updated_at      timestamptz default now() not null
);

create table muster.activity_events (
  id              bigserial primary key not null,
  organization_id bigint not null,
  entity_type     varchar(64) not null,
  entity_id       bigint not null,
  action          varchar(160) not null,
  detail          text,
  actor_id        bigint,
  created_at      timestamptz default now() not null
);

alter table muster.activity_events add constraint activity_events_organization_id_organizations_id_fk foreign key (organization_id) references muster.organizations(id);
alter table muster.activity_events add constraint activity_events_actor_id_users_id_fk foreign key (actor_id) references muster.users(id);
alter table muster.control_tests add constraint control_tests_control_id_controls_id_fk foreign key (control_id) references muster.controls(id);
alter table muster.control_tests add constraint control_tests_tester_id_users_id_fk foreign key (tester_id) references muster.users(id);
alter table muster.control_tests add constraint control_tests_reviewer_id_users_id_fk foreign key (reviewer_id) references muster.users(id);
alter table muster.controls add constraint controls_website_id_websites_id_fk foreign key (website_id) references muster.websites(id);
alter table muster.controls add constraint controls_owner_id_users_id_fk foreign key (owner_id) references muster.users(id);
alter table muster.evidence add constraint evidence_website_id_websites_id_fk foreign key (website_id) references muster.websites(id);
alter table muster.evidence add constraint evidence_owner_id_users_id_fk foreign key (owner_id) references muster.users(id);
alter table muster.evidence add constraint evidence_reviewed_by_id_users_id_fk foreign key (reviewed_by_id) references muster.users(id);
alter table muster.evidence_links add constraint evidence_links_evidence_id_evidence_id_fk foreign key (evidence_id) references muster.evidence(id);
alter table muster.evidence_links add constraint evidence_links_risk_id_risks_id_fk foreign key (risk_id) references muster.risks(id);
alter table muster.evidence_links add constraint evidence_links_control_id_controls_id_fk foreign key (control_id) references muster.controls(id);
alter table muster.organization_members add constraint organization_members_organization_id_organizations_id_fk foreign key (organization_id) references muster.organizations(id);
alter table muster.organization_members add constraint organization_members_user_id_users_id_fk foreign key (user_id) references muster.users(id);
alter table muster.organizations add constraint organizations_risk_owner_id_users_id_fk foreign key (risk_owner_id) references muster.users(id);
alter table muster.remediation_actions add constraint remediation_actions_risk_id_risks_id_fk foreign key (risk_id) references muster.risks(id);
alter table muster.remediation_actions add constraint remediation_actions_control_id_controls_id_fk foreign key (control_id) references muster.controls(id);
alter table muster.remediation_actions add constraint remediation_actions_owner_id_users_id_fk foreign key (owner_id) references muster.users(id);
alter table muster.remediation_milestones add constraint remediation_milestones_remediation_id_remediation_actions_id_fk foreign key (remediation_id) references muster.remediation_actions(id);
alter table muster.remediation_milestones add constraint remediation_milestones_owner_id_users_id_fk foreign key (owner_id) references muster.users(id);
alter table muster.remediation_milestones add constraint remediation_milestones_validated_by_id_users_id_fk foreign key (validated_by_id) references muster.users(id);
alter table muster.risk_appetites add constraint risk_appetites_organization_id_organizations_id_fk foreign key (organization_id) references muster.organizations(id);
alter table muster.risk_appetites add constraint risk_appetites_owner_id_users_id_fk foreign key (owner_id) references muster.users(id);
alter table muster.risk_control_mappings add constraint risk_control_mappings_risk_id_risks_id_fk foreign key (risk_id) references muster.risks(id);
alter table muster.risk_control_mappings add constraint risk_control_mappings_control_id_controls_id_fk foreign key (control_id) references muster.controls(id);
alter table muster.risk_exceptions add constraint risk_exceptions_risk_id_risks_id_fk foreign key (risk_id) references muster.risks(id);
alter table muster.risk_exceptions add constraint risk_exceptions_owner_id_users_id_fk foreign key (owner_id) references muster.users(id);
alter table muster.risk_exceptions add constraint risk_exceptions_approver_id_users_id_fk foreign key (approver_id) references muster.users(id);
alter table muster.risks add constraint risks_website_id_websites_id_fk foreign key (website_id) references muster.websites(id);
alter table muster.risks add constraint risks_owner_id_users_id_fk foreign key (owner_id) references muster.users(id);
alter table muster.strategic_objectives add constraint strategic_objectives_organization_id_organizations_id_fk foreign key (organization_id) references muster.organizations(id);
alter table muster.strategic_objectives add constraint strategic_objectives_owner_id_users_id_fk foreign key (owner_id) references muster.users(id);
alter table muster.websites add constraint websites_owner_id_users_id_fk foreign key (owner_id) references muster.users(id);
alter table muster.websites add constraint websites_organization_id_organizations_id_fk foreign key (organization_id) references muster.organizations(id);

create index activity_organization_idx on muster.activity_events using btree (organization_id);
create index activity_entity_idx on muster.activity_events using btree (entity_type, entity_id);
create index control_test_control_idx on muster.control_tests using btree (control_id);
create index control_test_status_idx on muster.control_tests using btree (test_status);
create unique index control_scope_unique on muster.controls using btree (website_id, framework, reference);
create index control_website_idx on muster.controls using btree (website_id);
create index control_owner_idx on muster.controls using btree (owner_id);
create index evidence_website_idx on muster.evidence using btree (website_id);
create index evidence_owner_idx on muster.evidence using btree (owner_id);
create index evidence_review_idx on muster.evidence using btree (review_state);
create index evidence_link_evidence_idx on muster.evidence_links using btree (evidence_id);
create index evidence_link_risk_idx on muster.evidence_links using btree (risk_id);
create index evidence_link_control_idx on muster.evidence_links using btree (control_id);
create unique index organization_member_unique on muster.organization_members using btree (organization_id, user_id);
create index organization_member_user_idx on muster.organization_members using btree (user_id);
create index remediation_risk_idx on muster.remediation_actions using btree (risk_id);
create index remediation_control_idx on muster.remediation_actions using btree (control_id);
create index remediation_owner_idx on muster.remediation_actions using btree (owner_id);
create index remediation_status_idx on muster.remediation_actions using btree (status);
create index milestone_remediation_idx on muster.remediation_milestones using btree (remediation_id);
create index milestone_status_idx on muster.remediation_milestones using btree (status);
create unique index appetite_organization_unique on muster.risk_appetites using btree (organization_id);
create unique index risk_control_unique on muster.risk_control_mappings using btree (risk_id, control_id);
create index risk_control_risk_idx on muster.risk_control_mappings using btree (risk_id);
create index risk_control_control_idx on muster.risk_control_mappings using btree (control_id);
create index exception_risk_idx on muster.risk_exceptions using btree (risk_id);
create index exception_status_idx on muster.risk_exceptions using btree (status);
create index exception_owner_idx on muster.risk_exceptions using btree (owner_id);
create index risk_website_idx on muster.risks using btree (website_id);
create index risk_owner_idx on muster.risks using btree (owner_id);
create index risk_status_idx on muster.risks using btree (status);
create index objective_organization_idx on muster.strategic_objectives using btree (organization_id);
create index objective_owner_idx on muster.strategic_objectives using btree (owner_id);
create index users_email_idx on muster.users using btree (email);
create index website_owner_idx on muster.websites using btree (owner_id);
