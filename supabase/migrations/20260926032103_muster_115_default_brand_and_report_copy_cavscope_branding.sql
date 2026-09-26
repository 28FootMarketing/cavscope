-- q_brand() is what every non-white-labeled SITREP, workspace header, and
-- report footer reads its product name from. It was still returning
-- 'MUSTER'/'MU' as the default brand_name/brand_mark and a "Prepared under
-- the MUSTER Assurance Framework" disclaimer -- meaning every customer
-- without white-label reads MUSTER on their own reports today. The
-- sentinel value 'mode':'muster' and the 'hide_muster_attribution' key name
-- are UNCHANGED on purpose: app.html compares against the literal string
-- 'muster' (deliverableMode === 'muster', <option value="muster">) and
-- reads that key by name, so those are the internal identifiers CLAUDE.md's
-- brand note is about -- only the two display strings and the mark change.
CREATE OR REPLACE FUNCTION muster.q_brand(p_org bigint, p_website_id bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  b muster.brand_profiles%rowtype;
  v_wl boolean := muster.has_flag(p_org, 'white_label_enabled');
  v_hide boolean := muster.has_flag(p_org, 'hide_attribution');
  v_domain boolean := muster.has_flag(p_org, 'custom_domain_enabled');
begin
  if p_website_id is not null then
    select * into b from muster.brand_profiles where website_id = p_website_id;
  end if;
  if b.id is null then
    select * into b from muster.brand_profiles where organization_id = p_org and website_id is null;
  end if;
  if b.id is null or not v_wl then
    return jsonb_build_object('is_custom', false, 'locked', not v_wl, 'mode', 'muster',
      'brand_name', 'CavScope', 'brand_mark', 'CS', 'eyebrow', '28 Foot Systems',
      'primary_color', '#36e2c9', 'accent_color', '#f5b942', 'logo_url', null, 'favicon_url', null,
      'report_disclaimer', 'Prepared under the CavScope Assurance Framework by 28 Foot Systems. All rights reserved.',
      'hide_muster_attribution', false, 'tone', 'executive', 'locale', 'en-US', 'custom_domain', null,
      'saved_profile', case when b.id is null then null else to_jsonb(b) end);
  end if;
  return to_jsonb(b) || jsonb_build_object('is_custom', true, 'locked', false, 'mode', 'white_label',
    'hide_muster_attribution', (b.hide_muster_attribution and v_hide),
    'custom_domain', case when v_domain then b.custom_domain else null end);
end;
$function$
;
