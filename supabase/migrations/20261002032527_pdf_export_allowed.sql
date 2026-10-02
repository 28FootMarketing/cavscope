-- Who may export a SITREP as a PDF: a member of the report's organization (or a super admin) with the
-- pdf_export flag on for it. The flag's kill switch stops everyone, super admins included, and ships ON,
-- so the feature is deployed but dark until an owner turns it off. Anon is revoked by name.
-- Proved in a rolled-back transaction on 2026-10-02: kill switch on, flag default off, org override on,
-- unknown report, non-member, signed in with no user row, and anon.
create or replace function public.cavscope_pdf_export_allowed(p_sitrep_id bigint)
returns boolean language plpgsql stable security definer set search_path = '' as $function$
declare v_org bigint;
begin
  if cavscope.current_user_id() is null then return false; end if;
  select organization_id into v_org from cavscope.sitreps where id = p_sitrep_id;
  if v_org is null then return false; end if;
  if exists (select 1 from cavscope.feature_flags where key = 'pdf_export' and kill_switch) then return false; end if;
  if not cavscope.is_org_member(v_org) then return false; end if;
  if cavscope.is_super_admin() then return true; end if;
  return cavscope.has_flag(v_org, 'pdf_export');
end;
$function$;
revoke all on function public.cavscope_pdf_export_allowed(bigint) from public, anon;
grant execute on function public.cavscope_pdf_export_allowed(bigint) to authenticated, service_role;
