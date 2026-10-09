-- Stage 5 evidence: has anything called a muster_* RPC alias, or requested a muster-*
-- edge-function slug, in a given 24-hour window?
--
-- The answer comes from the API gateway log, NOT from pg_stat_statements. The first
-- version of this file (2026-10-01) counted pg_stat_statements rows per muster_* name
-- and compared them against a CSV baseline. On 2026-10-09 every count had grown all
-- week while the gateway showed no old-name call since 2026-10-03. The counts were
-- real and the conclusion was wrong: the rename kept each function's OID
-- (public.cavscope_engine_secret is oid 19354, the original; muster_engine_secret is
-- a new wrapper, oid 26044), pg_stat_statements keys on the OID, and it keeps the
-- query text it saw first. So every PostgREST call to cavscope_engine_secret() is
-- counted on the row whose text still says "public"."muster_engine_secret"(). Proof,
-- run against hjowfnzpomzxazmzywxw:
--
--   select count(*) from pg_stat_statements where query ~ 'cavscope_engine_secret';
--   -- 0, against thousands of gateway calls a day to that name.
--
-- That check can never go quiet. Do not reintroduce it, and do not read the two
-- CSVs beside this file as evidence of anything; they are kept as the record of the
-- mistake.
--
-- What to run instead. The gateway log is a ClickHouse table reachable through the
-- Supabase MCP's query_logs tool or the dashboard's Logs Explorer. It answers at most
-- 24 hours per query, so a quiet week is seven runs with iso_timestamp_start and
-- iso_timestamp_end stepped a day at a time. An empty result for every window is the
-- evidence; any row is a caller to find (user agent, ASN and status code are in the
-- same row) and a restart of the clock.

select
  source,
  coalesce(nullif(log_attributes['request.path'], ''), log_attributes['request.pathname']) as p,
  log_attributes['request.headers.user_agent'] as ua,
  log_attributes['response.status_code'] as status,
  count() as n,
  max(timestamp) as last_seen
from logs
where (source = 'edge_logs'          and log_attributes['request.path']     like '/rest/v1/rpc/muster_%')
   or (source = 'function_edge_logs' and log_attributes['request.pathname'] like '/functions/v1/muster-%')
group by source, p, ua, status
order by n desc
limit 50;

-- Sweep of 2026-10-02 12:00 UTC through 2026-10-09 12:00 UTC, run 2026-10-09:
--   edge_logs          /rest/v1/rpc/muster_my_workspace, _claim_invites, _onboarding_status
--                      2 each, last 2026-10-03 03:21 UTC, iPad Chrome (a cached old page)
--   function_edge_logs /functions/v1/muster-agent/v1/models            2, status 200
--                      /functions/v1/muster-agent/v1/chat/completions  4, status 401
--                      last 2026-10-03 23:47 UTC, python-httpx from a Helsinki cloud host
--   every later window: no rows.
-- Quiet clock starts 2026-10-03 23:47 UTC; earliest stage 5 date 2026-10-11.
