-- Corrects a mistake in the immediately preceding migration
-- (muster_112_notification_category_registry_and_lifecycle_events), which
-- re-broke muster.do_add_website's URL validation.
--
-- muster_016 (2026-09-07) already fixed this exact defect once: muster_015's
-- do_add_website was transcribed with doubled backslashes ('\\.' in the URL
-- regex, '\\1' in the regexp_replace backreference), which -- with
-- standard_conforming_strings on, the default here -- makes the regex
-- require a LITERAL backslash character in the URL (so it rejected every
-- real address) and makes the backreference emit the literal string "\1"
-- instead of the captured hostname. muster_016 repaired the LIVE function via
-- pg_get_functiondef + chr(92) replacement, without touching muster_015's
-- immutable file text (migrations are append-only).
--
-- muster_112 added the sitrep-adjacent lifecycle notifications
-- (workspace_created, website_added) by copying do_add_website's body out of
-- muster_015's FILE text to extend it -- the original, still-broken,
-- doubled-backslash version, not the corrected live one -- and CREATE OR
-- REPLACE'd over muster_016's fix with it. Confirmed live and empirically
-- before writing this: 'https://example.com' !~*
-- '...[a-z0-9.-]+\\.[a-z]{2,}...' (false -- rejects a plain, valid URL) vs.
-- the single-backslash form (true -- matches). Caught before this branch
-- merged, via the test below and by hand against the live project; still
-- worth a permanent regression guard, since this is the second time the
-- identical transcription mistake has landed here.
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
  if v_url !~* '^https?://[a-z0-9.-]+\.[a-z]{2,}(:[0-9]+)?(/.*)?$' then
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

  v_website_name := left(coalesce(nullif(trim(p_name), ''), regexp_replace(v_url, '^https?://([^/]+).*$', '\1')), 160);
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
