-- Corrects the migration immediately before this one, which created
-- public.muster_engine_close_cleared_incidents and left it executable by anon and
-- authenticated -- the precise defect that migration was written to fix.
--
-- The root cause, and the reason the original two were vulnerable: Supabase ships
-- default privileges that GRANT EXECUTE on every new function in the public schema
-- to anon and authenticated. `revoke all ... from public` does not touch those,
-- because PUBLIC the pseudo-role and anon/authenticated the real roles are
-- different grantees. Every new public.muster_engine_* function is therefore
-- anon-callable from the moment it is created unless anon and authenticated are
-- named explicitly in a REVOKE.
--
-- Engine RPCs are called only by edge functions holding SUPABASE_SERVICE_ROLE_KEY.
-- None of them should ever be reachable with the publishable key, which ships in
-- page source.

revoke execute on function public.muster_engine_close_cleared_incidents(text, jsonb) from anon, authenticated;
revoke execute on function muster.close_cleared_incidents(text, jsonb) from anon, authenticated;