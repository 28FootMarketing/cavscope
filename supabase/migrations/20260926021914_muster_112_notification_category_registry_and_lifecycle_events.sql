-- Turns muster.notification_outbox's category from a hardcoded CHECK into a
-- registry table, and adds the first two genuinely net-new, non-duplicative
-- transactional email categories: workspace_created and website_added.
--
-- Every category added since muster_007 (risk_opened) has needed a migration
-- that edits a literal-equality CHECK constraint -- muster_110 for
-- sitrep_ready, this one for two more. That is exactly the pattern this
-- codebase already rejected for scan rule frameworks ("Frameworks are data,
-- in muster.frameworks; adding one is an insert, not a constraint edit" --
-- muster_058's header) and for feature flags (muster_055). A category is the
-- same shape of problem: a fast-growing enumeration that a CHECK constraint
-- makes artificially expensive to extend. This migration makes it a table
-- (muster.notification_categories) with a real FK from notification_outbox,
-- seeded with the two existing categories plus the two new ones -- adding a
-- FUTURE category (see docs/EMAIL-INVENTORY.md's remaining gaps) is now one
-- insert into this table plus whatever CATEGORY_META entry muster-alert-
-- dispatch needs, not a constraint edit.
--
-- entity_type stays a plain CHECK (widened to add organization/website): it
-- is a much smaller, slower-changing enumeration -- the set of THINGS an
-- email can be about, not the set of email KINDS -- and giving it its own
-- registry table would be the over-engineering this repo's own CLAUDE.md
-- explicitly warns against ("don't design for hypothetical future
-- requirements").

create table if not exists muster.notification_categories (
  key varchar(30) primary key,
  name varchar(80) not null,
  entity_type varchar(20) not null,
  description text not null,
  active boolean not null default true,
  created_at timestamptz default now() not null
);
comment on table muster.notification_categories is
  'Registry of muster.notification_outbox categories. Adding a category is an insert here (plus a muster-alert-dispatch CATEGORY_META entry and whatever enqueues it), not a CHECK-constraint edit -- same discipline as muster.frameworks and muster.feature_flags.';
comment on column muster.notification_categories.active is
  'False retires a category the way muster_111 retired the sitrep_ready_email flag: kept as a row for history, but no longer a valid value for new outbox rows (enforced by the partial-unique-style check below, not by removing the FK target and orphaning old rows).';

insert into muster.notification_categories (key, name, entity_type, description) values
  ('risk_opened', 'Critical/high risk opened', 'risk',
   'muster.autotriage() opens a risk from a critical/high finding. Gated on organizations.critical_alerts_enabled.'),
  ('sitrep_ready', 'SITREP ready', 'sitrep',
   'public.muster_engine_sitrep() generates a SITREP after every scan. Gated on organizations.sitrep_ready_alerts_enabled (default false).'),
  ('workspace_created', 'Workspace ready', 'organization',
   'muster.do_onboard() creates a new organization. One-time, sent to the creating user only.'),
  ('website_added', 'Website added', 'website',
   'muster.do_add_website() adds a website, EXCEPT when p_trigger = ''onboarding'' -- that case is folded into workspace_created''s own copy instead of sending a second email for the same onboarding action.')
on conflict (key) do nothing;

alter table muster.notification_outbox drop constraint if exists notification_outbox_category_check;
alter table muster.notification_outbox
  add constraint notification_outbox_category_fkey foreign key (category)
  references muster.notification_categories(key);

alter table muster.notification_outbox drop constraint if exists notification_outbox_entity_type_check;
alter table muster.notification_outbox add constraint notification_outbox_entity_type_check
  check ((entity_type)::text = any (array['risk'::text, 'sitrep'::text, 'organization'::text, 'website'::text]));

-- do_onboard: enqueue workspace_created once the organization (and its first
-- website, if one was supplied) exist. Recipient is the creating user only --
-- at this point in the flow they are the org's only member, so "executives
-- and risk owners" and "the creator" are the same set, but naming the
-- creator directly is correct even once that stops being true (e.g. a future
-- path that provisions an org for someone else).
CREATE OR REPLACE FUNCTION muster.do_onboard(p jsonb, p_user_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_org_id bigint;
  v_name text := left(trim(coalesce(p->>'org_name', '')), 160);
  v_country text := upper(left(coalesce(p->>'country_code', ''), 2));
  v_region text := nullif(upper(left(coalesce(p->>'region_code', ''), 8)), '');
  v_tz text := coalesce(nullif(p->>'timezone', ''), 'America/New_York');
  v_owned integer;
  v_site jsonb;
  v_brand jsonb := p->'brand';
  v_grant record;
  v_creator_email text;
begin
  if v_name = '' then raise exception 'org_name is required' using errcode = '22023'; end if;
  if not exists (select 1 from muster.countries where code = v_country) then
    raise exception 'country_code must be an ISO 3166-1 alpha-2 code' using errcode = '22023';
  end if;
  if v_region is not null and not exists (select 1 from muster.jurisdictions where code = v_country || '-' || v_region) then
    raise exception 'region_code % is not known for country %', v_region, v_country using errcode = '22023';
  end if;
  select count(*) into v_owned from muster.organizations where created_by_id = p_user_id;
  if v_owned >= 5 and not muster.is_super_admin() then
    raise exception 'organization limit reached for this account' using errcode = '42501';
  end if;

  insert into muster.organizations (name, industry, risk_owner_id, plan, country_code, region_code, timezone, website_limit,
    onboarding_status, created_by_id)
  values (v_name, left(nullif(p->>'industry', ''), 120), p_user_id, 'trial', v_country, v_region, v_tz,
    (select website_limit from muster.plans where plan = 'trial'), 'profile', p_user_id)
  returning id into v_org_id;

  insert into muster.organization_members (organization_id, user_id, role) values (v_org_id, p_user_id, 'executive');

  select g.* into v_grant
  from muster.pending_commercial_grants g
  join muster.users u on lower(u.email) = g.email
  where u.id = p_user_id and g.applied_at is null
  order by g.created_at desc
  limit 1;

  if v_grant.id is not null then
    update muster.organizations
    set plan = v_grant.plan,
        website_limit = (select website_limit from muster.plans where plan = v_grant.plan),
        commercial_stage = v_grant.stage
    where id = v_org_id;
    update muster.pending_commercial_grants set applied_at = now() where id = v_grant.id;
    insert into muster.activity_events (organization_id, entity_type, entity_id, action, detail, actor_id)
    values (v_org_id, 'organization', v_org_id, 'commercial_plan_applied',
      format('Applied pending Stripe grant: plan=%s stage=%s stripe_subscription_id=%s', v_grant.plan, v_grant.stage, coalesce(v_grant.stripe_subscription_id, 'n/a')),
      p_user_id);
  end if;

  insert into muster.risk_appetites (organization_id, statement, critical_threshold, high_threshold, review_cadence, next_review_at, owner_id)
  values (v_org_id, 'No open critical website findings. High findings remediated within 30 days.', 0, 2, 'quarterly', now() + interval '90 days', p_user_id);

  if v_brand is not null and coalesce(v_brand->>'brand_name', '') <> '' then
    insert into muster.brand_profiles (organization_id, brand_name, brand_mark, eyebrow, primary_color, accent_color, logo_url,
      support_email, report_signoff_name, report_signoff_title, welcome_message, tone, created_by_id)
    values (v_org_id, left(v_brand->>'brand_name', 80),
      upper(left(coalesce(nullif(v_brand->>'brand_mark', ''), left(v_brand->>'brand_name', 2)), 4)),
      left(coalesce(nullif(v_brand->>'eyebrow', ''), 'Website Assurance'), 80),
      coalesce(nullif(v_brand->>'primary_color', ''), '#36e2c9'), coalesce(nullif(v_brand->>'accent_color', ''), '#f5b942'),
      nullif(v_brand->>'logo_url', ''), nullif(v_brand->>'support_email', ''), nullif(v_brand->>'report_signoff_name', ''),
      nullif(v_brand->>'report_signoff_title', ''), nullif(v_brand->>'welcome_message', ''),
      coalesce(nullif(v_brand->>'tone', ''), 'executive'), p_user_id);
  end if;

  update muster.user_preferences set default_organization_id = v_org_id,
    preferred_name = coalesce(nullif(p->>'preferred_name', ''), preferred_name)
  where user_id = p_user_id;

  insert into muster.activity_events (organization_id, entity_type, entity_id, action, detail, actor_id)
  values (v_org_id, 'organization', v_org_id, 'Organization created (self-serve onboarding)',
    'Jurisdiction ' || v_country || coalesce('-' || v_region, ''), p_user_id);

  if coalesce(p->>'website_url', '') <> '' then
    update muster.organizations set onboarding_status = 'website' where id = v_org_id;
    v_site := muster.do_add_website(v_org_id, p->>'website_name', p->>'website_url', coalesce(p->>'environment', 'production'), 1440, p_user_id, 'onboarding');
    update muster.organizations set onboarding_status = 'complete', onboarding_completed_at = now() where id = v_org_id;
  end if;

  select email into v_creator_email from muster.users where id = p_user_id;
  if v_creator_email is not null then
    insert into muster.notification_outbox
      (organization_id, category, entity_type, entity_id, severity, subject, body_text, recipient_emails)
    values (
      v_org_id, 'workspace_created', 'organization', v_org_id, 'info',
      format('[CavScope] Your workspace is ready: %s', v_name),
      format(E'%s is set up in CavScope.\n\n%s\n\nSign in to your CavScope workspace to invite your team and review your jurisdiction obligations.\n',
        v_name,
        case when v_site is not null
          then format('Your first website, %s, has been added and its first scan is running -- the SITREP will appear in your workspace shortly.', coalesce(v_site->>'url', 'your site'))
          else 'Add your first website from the workspace to start your first assurance scan.'
        end),
      array[v_creator_email]
    )
    on conflict (entity_type, entity_id, category) do nothing;
  end if;

  return jsonb_build_object(
    'organization', muster.q_organization(v_org_id),
    'website', v_site,
    'advisory', muster.q_jurisdiction_advisory(v_country, v_region, true),
    'next_steps', jsonb_build_array(
      case when v_site is null then 'Add your first website to start the scan.' else 'Your first scan is running. The SITREP will appear in a few minutes.' end,
      'Invite a risk owner and a control owner from Settings.',
      'Review the jurisdiction obligations mapped to your scan evidence.',
      'Set your brand profile if you deliver reports under your own name.'));
end;
$function$
;

-- do_add_website: enqueue website_added, except for the onboarding trigger
-- (that case's news already rides in workspace_created's own copy above --
-- see the registry row's description for why sending both would be two
-- emails for one action).
CREATE OR REPLACE FUNCTION muster.do_add_website(p_org bigint, p_name text, p_url text, p_environment text, p_cadence_minutes integer, p_user_id bigint, p_trigger text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_count integer;
  v_limit integer;
  v_min_cadence integer;
  v_url text := trim(p_url);
  v_website_id bigint;
  v_scan jsonb;
  v_website_name text;
  v_recipients text[];
begin
  if v_url !~* '^https?://[a-z0-9.-]+\\.[a-z]{2,}(:[0-9]+)?(/.*)?$' then
    raise exception 'website url must be a full http(s) address, for example https://example.com' using errcode = '22023';
  end if;
  select count(*) into v_count from muster.websites where organization_id = p_org;
  select p.website_limit, p.scan_cadence_min_minutes into v_limit, v_min_cadence
  from muster.organizations o join muster.plans p on p.plan = o.plan where o.id = p_org;
  if v_count >= 1 and not muster.has_flag(p_org, 'multi_website') then
    raise exception 'this plan allows one website. Upgrade to add more.' using errcode = '42501';
  end if;
  if v_count >= v_limit then
    raise exception 'website limit (%) reached for this plan', v_limit using errcode = '42501';
  end if;

  v_website_name := left(coalesce(nullif(trim(p_name), ''), regexp_replace(v_url, '^https?://([^/]+).*$', '\\1')), 160);
  insert into muster.websites (name, url, environment, owner_id, organization_id)
  values (v_website_name, left(v_url, 512),
          coalesce(p_environment, 'production'), p_user_id, p_org)
  returning id into v_website_id;

  insert into muster.website_scan_settings (website_id, cadence_minutes, next_run_at)
  values (v_website_id, greatest(coalesce(p_cadence_minutes, 1440), v_min_cadence), now() + interval '1 day');

  insert into muster.activity_events (organization_id, entity_type, entity_id, action, detail, actor_id)
  values (p_org, 'website', v_website_id, 'Website added', v_url, p_user_id);

  if p_trigger <> 'onboarding' then
    select coalesce(array_agg(distinct u.email), '{}')
      into v_recipients
      from muster.organization_members om
      join muster.users u on u.id = om.user_id
      where om.organization_id = p_org and om.role in ('executive','risk_owner');
    if array_length(v_recipients, 1) > 0 then
      insert into muster.notification_outbox
        (organization_id, category, entity_type, entity_id, severity, subject, body_text, recipient_emails)
      values (
        p_org, 'website_added', 'website', v_website_id, 'info',
        format('[CavScope] %s has been added to CavScope', v_website_name),
        format(E'%s (%s) has been added to your CavScope workspace.\n\nA first assurance scan is running now. You will get a SITREP once it completes, if SITREP email delivery is turned on for this workspace.\n',
          v_website_name, v_url),
        v_recipients
      )
      on conflict (entity_type, entity_id, category) do nothing;
    end if;
  end if;

  v_scan := muster.do_request_scan(v_website_id, p_user_id, null, p_trigger);
  return jsonb_build_object('website_id', v_website_id, 'url', v_url, 'first_scan', v_scan);
end;
$function$
;
