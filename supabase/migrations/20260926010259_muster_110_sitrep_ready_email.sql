-- SITREP-ready notification email (docs/EMAIL-INVENTORY.md "Real gaps, not yet
-- built"). A SITREP is generated synchronously, unconditionally, right after
-- EVERY scan (public.muster_engine_sitrep, called from muster-scan/index.ts
-- immediately after ingest -- scheduled, manual and admin-sandbox scans alike).
-- So "SITREP ready" and "scan complete" are the same event for this engine.
-- This migration adds exactly ONE new outbox category, not two: two categories
-- firing off one event is precisely the one-owner-per-event failure
-- docs/EMAIL-INVENTORY.md exists to prevent.
--
-- The OTHER named gap in that doc -- "subscription activated for an existing
-- user" -- is deliberately NOT added here. muster.do_onboard is the only place
-- a pending commercial grant is ever applied to an organization's plan, and it
-- only runs when a NEW organization is created (muster_014). There is no code
-- path today that applies a grant to an EXISTING organization, so a
-- "subscription activated" email at checkout time would claim a plan change
-- the schema cannot yet confirm happened -- the same class of bug as the
-- AVAIL-001 false "site down" report (muster_065/muster_073's header): a
-- confident claim about something the code never actually read. That gap needs
-- an existing-org upgrade path first; bolting an email onto checkout without
-- one would ship a lie, not a notification.

alter table muster.notification_outbox drop constraint if exists notification_outbox_category_check;
alter table muster.notification_outbox add constraint notification_outbox_category_check
  check ((category)::text = any (array['risk_opened'::text, 'sitrep_ready'::text]));

alter table muster.notification_outbox drop constraint if exists notification_outbox_entity_type_check;
alter table muster.notification_outbox add constraint notification_outbox_entity_type_check
  check ((entity_type)::text = any (array['risk'::text, 'sitrep'::text]));

alter table muster.notification_outbox drop constraint if exists notification_outbox_severity_check;
alter table muster.notification_outbox add constraint notification_outbox_severity_check
  check ((severity)::text = any (array['critical'::text, 'high'::text, 'info'::text]));

-- Flag registry entry, added in the same migration as the code that reads it
-- (muster.feature_flags's own rule -- see muster_055's header). Ships
-- default_enabled = false: muster.websites defaults to a 1440-minute (daily)
-- scan cadence, and there is no workspace-settings UI yet for an org to turn a
-- daily "your SITREP is ready" email off itself. Same discipline as
-- SEC-014/AVAIL-004: ship the mechanism inactive, turn it on per org via
-- feature_flag_overrides (or flip default_enabled once a settings toggle
-- exists), once observed correct against a real org.
insert into muster.feature_flags
  (key, name, description, scope, default_enabled, plan_minimum, kill_switch, category, surface, enforcement, wiring_note)
values (
  'sitrep_ready_email', 'SITREP Ready Email',
  'Notifies an organization''s SITREP recipients (organizations.sitrep_recipients, falling back to executive/risk_owner members) by email when a new SITREP is generated, via the same muster.notification_outbox / muster-alert-dispatch Resend path as risk_opened. Off by default: websites default to a 1440-minute (daily) scan cadence and there is no workspace-settings UI yet for an org to turn a daily email off itself. Enable per org with a feature_flag_overrides row, or flip default_enabled once a settings UI exists.',
  'organization', false, null, false, 'notifications', 'public.muster_engine_sitrep', array['sql'], null
)
on conflict (key) do update set
  description = excluded.description, category = excluded.category, surface = excluded.surface,
  enforcement = excluded.enforcement, wiring_note = excluded.wiring_note;

-- Same function, same signature, same grants (CREATE OR REPLACE preserves the
-- OID and privileges of an existing function) -- only the body gains the
-- sitrep_ready enqueue, gated behind flag_state_for_org (no user context: this
-- runs from the engine, called with the service-role key, same reasoning
-- muster_056 gives for why flag_state_for_org rather than has_flag on that
-- side). When the flag is off (the shipped default), this function's
-- observable behaviour is byte-for-byte what it was before this migration.
CREATE OR REPLACE FUNCTION public.muster_engine_sitrep(p_scan_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_id bigint;
  v_org bigint;
  v_website_id bigint;
  v_website_name varchar;
  v_recipients text[];
  v_sitrep muster.sitreps%rowtype;
begin
  select organization_id, website_id into v_org, v_website_id from muster.scans where id = p_scan_id;
  if not muster.has_flag(v_org, 'sitrep_generation') then
    return jsonb_build_object('skipped', true, 'reason', 'sitrep_generation flag off');
  end if;
  v_id := muster.generate_sitrep(p_scan_id);
  select * into v_sitrep from muster.sitreps where id = v_id;

  if muster.flag_state_for_org(v_org, 'sitrep_ready_email') then
    select o.sitrep_recipients into v_recipients from muster.organizations o where o.id = v_org;
    if v_recipients is null or array_length(v_recipients, 1) is null then
      select coalesce(array_agg(distinct u.email), '{}')
        into v_recipients
        from muster.organization_members om
        join muster.users u on u.id = om.user_id
        where om.organization_id = v_org and om.role in ('executive','risk_owner');
    end if;
    select w.name into v_website_name from muster.websites w where w.id = v_website_id;
    if array_length(v_recipients, 1) > 0 then
      insert into muster.notification_outbox
        (organization_id, category, entity_type, entity_id, severity, subject, body_text, recipient_emails)
      values (
        v_org, 'sitrep_ready', 'sitrep', v_id, 'info',
        format('[CavScope] SITREP ready: %s (%s)', v_website_name, v_sitrep.posture_band),
        format(E'A new SITREP is ready for %s.\n\nPosture: %s (%s/100)\n\n%s\n\nSign in to your CavScope workspace to view the full report.\n',
          v_website_name, v_sitrep.posture_band, v_sitrep.posture_score, v_sitrep.headline),
        v_recipients
      )
      on conflict (entity_type, entity_id, category) do nothing;
    else
      insert into muster.activity_events (organization_id, entity_type, entity_id, action, detail)
      values (v_org, 'sitrep', v_id, 'alert_skipped_no_recipient',
        'sitrep_ready_email is on but no sitrep_recipients set and no executive/risk_owner member found');
    end if;
  end if;

  return jsonb_build_object('sitrep_id', v_id, 'headline', v_sitrep.headline, 'posture_score', v_sitrep.posture_score, 'posture_band', v_sitrep.posture_band);
end;
$function$
;
