-- muster.q_org_scans is an internal helper (like every other muster.q_* function); it must not
-- carry the default PUBLIC execute grant Postgres attaches to newly created functions. Only the
-- public.muster_org_scans wrapper (which enforces is_org_member) should be callable by clients.
revoke execute on function muster.q_org_scans(bigint, integer, integer, bigint, text) from public, anon, authenticated;
grant execute on function muster.q_org_scans(bigint, integer, integer, bigint, text) to service_role;
