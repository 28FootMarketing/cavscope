-- MUSTER cutover housekeeping on the OLD shared project.
--
-- public.apply_approved_kb_updates() is JARVIS's approval executor, run every
-- ten minutes by the active cron job kb-update-executor-10min. It handles two
-- categories:
--
--   kb_update          -> public.kb_documents          (CORA/JARVIS, unaffected)
--   muster_law_update  -> muster.jurisdiction_laws     (MUSTER, now decommissioned here)
--
-- MUSTER moved to hjowfnzpomzxazmzywxw on 2026-09-08. That table on THIS project
-- is a decommissioned copy that nothing reads any more.
--
-- The failure this prevents is not a crash. If a muster_law_update approval were
-- ever filed, the executor would update the dead table, close the diff, and stamp
-- the approval execution_result = {"ok": true}. The operator would see a
-- successful law update that never reached production. A false success in an
-- audit trail is worse than a visible failure, because nothing ever prompts
-- anyone to look.
--
-- Neither category has ever had a row (0 muster_law_update, 0 kb_update; the
-- volume in jarvis_approvals is 235 content, plus comms/compliance_review/agents/
-- rnd_prototype/Testing/User Management). So this is a latent trap being closed,
-- not a live integration being cut.
--
-- WHAT IS DELIBERATELY NOT CHANGED. The kb_update and company_id branches are
-- byte-identical, the rejected-diff sweep at the end is untouched, and
-- kb-update-executor-10min keeps running. This function belongs to JARVIS; only
-- the branch that reaches into MUSTER's schema is MUSTER's to retire, and it is
-- retired per-row so one refused MUSTER approval can never block JARVIS's own
-- work in the same pass.
--
-- search_path drops 'muster': after this the function does not reference that
-- schema at all, and leaving it resolvable would invite the same mistake back.
--
-- The verification below tests for the write statement rather than the bare
-- table name, because the operator-facing reason string deliberately names the
-- table and an over-broad check matches its own explanation. That is not
-- hypothetical -- the first version of this migration failed on exactly that.
--
-- STILL OPEN, AND A PRODUCT DECISION RATHER THAN A TASK: whether JARVIS should
-- be able to propose MUSTER law updates at all now that MUSTER is a separate
-- product on a separate project. Zero such approvals have ever been filed, so
-- there is no demonstrated need. If the answer is yes, it needs an explicit
-- cross-project path on hjowfnzpomzxazmzywxw -- not a resurrection of this
-- branch.

create or replace function public.apply_approved_kb_updates()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare r record; n int := 0;
begin
  for r in
    select id, category, action from public.jarvis_approvals
    where category in ('kb_update','muster_law_update') and status = 'approved' and executed_at is null
  loop
    if r.category = 'muster_law_update' then
      update public.jarvis_approvals
         set executed_at = now(),
             execution_result = jsonb_build_object(
               'ok', false,
               'at', now(),
               'reason', 'muster_law_update is not executable on this project. MUSTER moved to hjowfnzpomzxazmzywxw on 2026-09-08 and muster.jurisdiction_laws here is a decommissioned copy that nothing reads. Apply law changes on the MUSTER project.')
       where id = r.id;
      continue;
    end if;

    if r.action->>'kb_document_id' is not null then
      update public.kb_documents
        set content = r.action->>'new_content', title = coalesce(r.action->>'new_title', title)
      where id = (r.action->>'kb_document_id')::uuid;
    elsif r.action->>'company_id' is not null then
      insert into public.kb_documents (company_id, title, content, source, doc_type, is_active)
      values ((r.action->>'company_id')::uuid, r.action->>'new_title', r.action->>'new_content',
              coalesce(r.action->>'source','site_watch'), coalesce(r.action->>'doc_type','faq'), true);
    end if;
    update public.site_watch_diffs set status='closed', closed_at=now() where id = (r.action->>'diff_id')::uuid;
    update public.jarvis_approvals set executed_at = now(), execution_result = jsonb_build_object('ok', true, 'at', now()) where id = r.id;
    n := n + 1;
  end loop;
  update public.site_watch_diffs d set status='ignored', closed_at=now()
    from public.jarvis_approvals a where a.id = d.approval_id and a.status='rejected' and d.status='queued';
  return n;
end $function$;

do $$
declare
  v_acl text;
  v_cfg text;
  v_src text;
begin
  select array_to_string(p.proacl,' | '), p.proconfig::text, p.prosrc
    into v_acl, v_cfg, v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'apply_approved_kb_updates';

  if v_acl is distinct from 'postgres=X/postgres | service_role=X/postgres' then
    raise exception 'ACL changed to %', v_acl;
  end if;
  if v_cfg is distinct from '{search_path=public}' then
    raise exception 'search_path is %, expected public only', v_cfg;
  end if;

  -- the WRITE must be gone; the name may still appear in the reason string
  if v_src ilike '%update muster.jurisdiction_laws%' then
    raise exception 'function still writes to the decommissioned laws table';
  end if;
  if v_src not ilike '%muster_law_update is not executable on this project%' then
    raise exception 'the refusal reason is missing';
  end if;

  -- JARVIS's own paths must survive verbatim
  if v_src not ilike '%public.kb_documents%' then
    raise exception 'kb_documents branch lost';
  end if;
  if v_src not ilike '%site_watch_diffs%' then
    raise exception 'site_watch_diffs handling lost';
  end if;

  -- and it must still run clean
  perform public.apply_approved_kb_updates();
end $$;
