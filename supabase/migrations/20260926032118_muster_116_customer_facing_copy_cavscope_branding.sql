-- Same technique as muster_016 (2026-09-07): read each definition back out
-- of the catalog and do a plain-text replace, rather than retyping bodies --
-- generate_sitrep alone is 16KB, and retyping is exactly what caused the
-- backslash regression fixed two migrations ago in this same session.
--
-- Fixes customer- and agent-facing display copy that still said "MUSTER"
-- (uppercase, the brand word) after the CavScope rebrand: the SITREP
-- document itself (generate_sitrep, sitrep_jurisdiction_md,
-- sitrep_report_model), the jurisdiction advisory disclaimer
-- (q_jurisdiction_advisory), control-register citation text (sync_controls),
-- risk/evidence text written when a finding is promoted (do_promote_finding),
-- brand-settings plan-gate error messages a tenant can actually see
-- (muster_save_brand), the beta-signup deadline message
-- (muster_beta_signup_guard), and the MCP agent tool catalog description an
-- AI agent reads (agent_tools).
--
-- A plain case-sensitive 'MUSTER' -> 'CavScope' word replace is safe here:
-- none of these functions contain a MUSTER_-prefixed identifier (those are
-- edge-function env var names, not SQL), and the lowercase sentinel value
-- 'muster' (q_brand's 'mode' field, compared literally by app.html) and the
-- hide_muster_attribution column/key name are untouched by a case-sensitive
-- match -- confirmed by inspecting every match before writing this.
--
-- Deliberately left alone: admin_sandbox_org (an internal sandbox org name,
-- never shown to a real tenant), rule_control_refs and
-- muster_engine_record_email_event/muster_engine_search_docs (SQL comments,
-- not data), muster_admin_impersonate_start/end and
-- muster_admin_set_checkout_url (super-admin-console-only audit text and
-- error messages), and muster_set_llm_config (a Vault secret description,
-- never displayed to anyone). Verified by re-querying pg_proc.prosrc for the
-- literal substring 'MUSTER' after this migration and confirming only that
-- list remains.
--
-- 'MUSTER Partner' (the plan-gate messages in muster_save_brand) becomes
-- 'CavScope Partner tier', matching how CLAUDE.md and the rest of this
-- codebase already refer to the tier ("sold on the Partner tier").
do $$
declare
  d text;
begin
  for d in
    select pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'muster'
      and p.proname in (
        'generate_sitrep', 'q_jurisdiction_advisory', 'sitrep_jurisdiction_md',
        'sitrep_report_model', 'sync_controls', 'do_promote_finding', 'agent_tools'
      )
  loop
    execute replace(d, 'MUSTER', 'CavScope');
  end loop;

  for d in
    select pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('muster_beta_signup_guard')
  loop
    execute replace(d, 'MUSTER', 'CavScope');
  end loop;

  for d in
    select pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('muster_save_brand')
  loop
    execute replace(replace(d, 'the MUSTER Partner tier', 'the CavScope Partner tier'), 'MUSTER', 'CavScope');
  end loop;
end $$;
