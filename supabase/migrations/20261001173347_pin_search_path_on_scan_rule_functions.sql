-- Supabase's security advisor flagged three functions for a role-mutable search_path
-- (lint 0011_function_search_path_mutable): the scan-rule lifecycle audit added in
-- muster_scan_rule_lifecycle_audit (20260925051327).
--
-- All three are SECURITY INVOKER plpgsql, and every relation they touch is already
-- schema-qualified (cavscope.scan_rules, cavscope.scan_rule_history). The only
-- unqualified names are built-ins (set_config, current_setting, coalesce, nullif, now),
-- which resolve from pg_catalog, and pg_catalog is searched first even when
-- search_path is empty. So pinning it to '' changes no behaviour and removes the
-- ability to redirect an unqualified name by changing search_path.
--
-- ALTER FUNCTION ... SET rather than CREATE OR REPLACE: the bodies are not retyped, so
-- they cannot drift from what was applied.

alter function cavscope.log_scan_rule_change() set search_path = '';
alter function cavscope.scan_rule_retire(text, text, text, text) set search_path = '';
alter function cavscope.scan_rule_set_active(text, boolean, text, text, text) set search_path = '';
