-- Stage 5 evidence: has anything called a muster_* RPC since the callers were switched?
--
-- pg_stat_statements counts every statement since 2026-09-07 and is cumulative, so
-- the answer is a DIFFERENCE against docs/rename/calls-baseline-2026-10-01.csv, not
-- the raw number. track_functions cannot be set from the MCP role (superuser only), and
-- this works without it. Run read-only against hjowfnzpomzxazmzywxw.
--
-- The pattern allows an optional closing quote before "(" because PostgREST writes
-- calls as "public"."muster_x"(...). Without it the counts are about 1/100th of the
-- truth (found when the first baseline came back at 376 calls instead of 37,976).
--
-- Two things to check alongside, or a quiet result proves nothing:
--   * dealloc must be 0. When pg_stat_statements evicts entries (it holds 5000), a
--     rarely-called name can disappear and look unused.
--   * a name present in the baseline and absent now is NOT evidence of silence for
--     the same reason; only "same count as the baseline" is.
-- Names whose count grew since the baseline are still being called: find the caller
-- (API gateway logs show the path /rest/v1/rpc/<name>) before dropping the alias.

with hits as (
  select (regexp_matches(query, '(muster_[a-z0-9_]+)"?\s*\(', 'g'))[1] as fn, calls
  from pg_stat_statements
  where query ~ 'muster_[a-z0-9_]+"?\s*\('
    and query !~* '^\s*(create|alter|drop|comment|grant|revoke|do)\M'
)
select fn, sum(calls)::bigint as calls
from hits group by fn order by fn;

-- Evictions so far (must be 0 for the comparison to mean anything):
select dealloc, stats_reset from pg_stat_statements_info;
