-- The HTML audit: paste a page's HTML, run the scan engine's page rules on it,
-- apply the fixes the operator chooses, take the fixed HTML back. For a one-off
-- site CavScope does not scan. The rules are muster-scan/page-checks.ts, the
-- same module the engine runs; the function is cavscope-html-audit.
--
-- Super admins only to start, as the owner directed on 2026-09-30, behind a
-- flag so it can be turned on for a workspace later without a deploy. Off by
-- default for every organization. A per-organization override (admin.html,
-- Feature Flags) turns it on for that workspace's members.
--
-- The gate is this function, not the page and not the nav. The edge function
-- calls it with the caller's own JWT before it reads a byte of the HTML, so a
-- hidden nav item is an explanation and this is the enforcement.
--
-- Kill switch off means off for everyone, super admins included: a kill switch
-- that the most privileged account walks past is not one.

insert into cavscope.feature_flags
  (key, name, description, scope, default_enabled, plan_minimum, kill_switch, category, surface, enforcement, wiring_note)
values
  ('html_audit', 'HTML audit',
   'Paste a web page''s HTML, audit it with the scan engine''s page rules, apply fixes and download the corrected HTML. For sites CavScope does not scan. Super admins always have it; a workspace gets it only through an override here.',
   'organization', false, null, false, 'workspace', 'public.cavscope_html_audit_allowed / cavscope-html-audit / app.html nav',
   array['sql', 'app'], null)
on conflict (key) do nothing;

create or replace function public.cavscope_html_audit_allowed()
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid bigint := cavscope.current_user_id();
begin
  if v_uid is null then return false; end if;
  if exists (select 1 from cavscope.feature_flags where key = 'html_audit' and kill_switch) then return false; end if;
  if cavscope.is_super_admin() then return true; end if;
  return exists (
    select 1 from cavscope.organization_members m
    where m.user_id = v_uid and cavscope.has_flag(m.organization_id, 'html_audit')
  );
end;
$$;

revoke all on function public.cavscope_html_audit_allowed() from public, anon;
grant execute on function public.cavscope_html_audit_allowed() to authenticated, service_role;

do $$
begin
  if has_function_privilege('anon', 'public.cavscope_html_audit_allowed()', 'execute') then
    raise exception 'cavscope_html_audit_allowed is callable by anon';
  end if;
  if not exists (select 1 from cavscope.feature_flags where key = 'html_audit' and not default_enabled and enforcement = array['sql', 'app']) then
    raise exception 'html_audit flag row is not as declared';
  end if;
  -- No JWT in a migration: the gate must answer false, not raise.
  if public.cavscope_html_audit_allowed() then
    raise exception 'html audit gate allowed a caller with no identity';
  end if;
end $$;
