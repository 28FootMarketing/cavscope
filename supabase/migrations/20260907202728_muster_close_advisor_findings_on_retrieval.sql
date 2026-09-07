-- Closes the three advisor findings that belong to the retrieval work shipped
-- today. Found during a pre-launch readiness audit, not by the tests -- the
-- contract tests check behaviour, and none of these change behaviour.
--
-- 1. ERROR rls_disabled_in_public: muster.embedding_queue had RLS off.
--
--    Not currently reachable: the muster schema is NOT exposed to PostgREST
--    (verified live -- an anon request with Accept-Profile: muster returns
--    PGRST106 "Only the following schemas are exposed: public, brd, lms, ros,
--    storage, graphql_public"). So this was defence in depth, not an open door.
--    It is enabled anyway, because "not exposed" is a project setting someone
--    can change in a dashboard, and the table should not become readable the
--    moment they do.
--
--    No policies are added. Everything that touches this table does so as
--    postgres (the owner, via SECURITY DEFINER RPCs) or service_role, and both
--    bypass RLS. The four enqueue triggers are SECURITY INVOKER but only ever
--    fire inside those same paths, so they bypass too. A policy here would only
--    grant access nothing needs.
--
-- 2/3. WARN function_search_path_mutable on muster.q_search_findings and
--    muster.q_search_evidence: proconfig was null, i.e. no search_path at all.
--
--    These are SECURITY INVOKER (prosecdef = false), so this is not a
--    privilege-escalation path the way it would be for a definer function --
--    they run as the caller and RLS applies. It is still pinned, because an
--    unpinned search_path on a function doing vector operator lookups is how
--    the `operator does not exist: public.vector <-> public.vector` outage
--    happened in the first place.
--
--    Written as two bare identifiers. `SET search_path TO 'public, muster'` is
--    ONE quoted identifier, silently leaves muster off the path, and breaks
--    every <-> in the body. That mistake shipped in eight functions and killed
--    both search wrappers end to end; see
--    20260907053748_muster_fix_malformed_search_path_quoting.
--
--    PUBLIC EXECUTE is also revoked. The earlier lockdown
--    (20260907083752_muster_revoke_public_execute_on_search_wrappers) revoked
--    on the public.muster_engine_search_* wrappers but missed these inner
--    functions, which still carried PUBLIC:EXECUTE. The wrappers are SECURITY
--    DEFINER owned by postgres, so they continue to reach these after the
--    revoke; only direct callers lose access, and there are none.

alter table muster.embedding_queue enable row level security;

alter function muster.q_search_findings(bigint, public.vector, int, float)
  set search_path = public, muster;
alter function muster.q_search_evidence(bigint, public.vector, int, float)
  set search_path = public, muster;

revoke execute on function muster.q_search_findings(bigint, public.vector, int, float) from public, anon, authenticated;
revoke execute on function muster.q_search_evidence(bigint, public.vector, int, float) from public, anon, authenticated;
