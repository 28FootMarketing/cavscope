-- Deterministic contract tests for MUSTER retrieval.
--
-- Every test here is a regression for a defect that actually shipped and was
-- found by hand on 2026-09-07. None of them needs a model call, which is the
-- point: the failures that reached production were contract failures, not
-- behavioural ones.
--
--   1 search_path_well_formed        malformed SET search_path 'public, muster'
--                                    killed both search wrappers outright
--   2 retrieval_grants_locked        search wrappers + backfill helpers were
--                                    executable by anon (cross-tenant read, and
--                                    an unauthenticated write into the index)
--   3 findings_self_match_is_one     scoring sanity
--   4 evidence_self_match_is_one     q_search_evidence used 1-L2 while
--   5 threshold_scales_agree         q_search_findings used 1-L2^2/4, so evidence
--                                    never cleared the shared 0.6 default
--   6 evidence_limit_counts_distinct finding_evidence join spent p_limit on dupes
--   7 evidence_linkage_preserved     the dedupe must not lose finding linkage
--   8 org_scope_denies_mismatch      positive control on tenant isolation
--   9 org_scope_denies_missing_org   see the correction migration that follows
--  10 embeddings_complete            operational: nothing left unembedded
--
-- Read-only. Invoker rights on purpose: this is a test harness, not another
-- SECURITY DEFINER surface, and the same day already produced two of those by
-- accident. No grants, so only postgres and service_role can run it.
--
-- NOTE: test 9 in this revision asserts the wrong contract and fails. It is kept
-- as applied, and corrected in 20260908160000, which explains why.

create or replace function muster.test_retrieval_contract()
returns table(test text, passed boolean, detail text)
language plpgsql
set search_path = public, muster, pg_temp
as $fn$
declare
  v_site bigint; v_org bigint; v_emb public.vector;
  v_ev_site bigint; v_ev_emb public.vector;
  v_n int; v_distinct int; v_sim double precision; v_bad int;
begin
  select fe.website_id, fe.embedding into v_site, v_emb
    from muster.finding_embeddings fe order by fe.finding_id limit 1;
  select w.organization_id into v_org from muster.websites w where w.id = v_site;
  select ee.website_id, ee.embedding into v_ev_site, v_ev_emb
    from muster.evidence_embeddings ee
    join muster.finding_evidence fev on fev.evidence_id = ee.evidence_id
    join muster.findings f on f.id = fev.finding_id and f.status in ('open','reopened')
    order by ee.evidence_id limit 1;

  if v_emb is null then
    return query select 'fixtures_available', false, 'no finding embeddings; cannot run retrieval contract';
    return;
  end if;
  return query select 'fixtures_available', true, format('website %s, org %s', v_site, v_org);

  begin
    select count(*) into v_n from pg_proc p
      cross join lateral unnest(coalesce(p.proconfig, '{}')) cfg
     where cfg = 'search_path="public, muster"';
    return query select 'search_path_well_formed', v_n = 0,
      case when v_n = 0 then 'no malformed search_path settings'
           else format('%s function(s) still quote the whole list as one identifier', v_n) end;
  exception when others then return query select 'search_path_well_formed', false, sqlerrm; end;

  begin
    select count(*) into v_bad from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f'
       and p.proname in ('muster_engine_search_findings','muster_engine_search_evidence',
                         'insert_finding_embedding','insert_evidence_embedding',
                         'get_findings_without_embeddings','get_evidence_without_embeddings',
                         'count_findings_without_embeddings','count_evidence_without_embeddings')
       and (has_function_privilege('anon', p.oid, 'EXECUTE')
         or has_function_privilege('authenticated', p.oid, 'EXECUTE'));
    return query select 'retrieval_grants_locked', v_bad = 0,
      case when v_bad = 0 then 'all 8 retrieval functions are service_role only'
           else format('%s retrieval function(s) reachable by anon/authenticated', v_bad) end;
  exception when others then return query select 'retrieval_grants_locked', false, sqlerrm; end;

  begin
    select s.similarity into v_sim from muster.q_search_findings(v_site, v_emb, 1, 0) s limit 1;
    return query select 'findings_self_match_is_one', round(v_sim::numeric, 4) = 1.0,
      format('top self-probe similarity %s', round(coalesce(v_sim, -1)::numeric, 4));
  exception when others then return query select 'findings_self_match_is_one', false, sqlerrm; end;

  begin
    if v_ev_emb is null then
      return query select 'evidence_self_match_is_one', true, 'skipped: no evidence linked to an open finding';
    else
      select s.similarity into v_sim from muster.q_search_evidence(v_ev_site, v_ev_emb, 1, 0) s limit 1;
      return query select 'evidence_self_match_is_one', round(v_sim::numeric, 4) = 1.0,
        format('top self-probe similarity %s', round(coalesce(v_sim, -1)::numeric, 4));
    end if;
  exception when others then return query select 'evidence_self_match_is_one', false, sqlerrm; end;

  begin
    select count(*) into v_n from muster.q_search_findings(v_site, v_emb, 5, 0.6);
    select count(*) into v_distinct from muster.q_search_evidence(
      coalesce(v_ev_site, v_site), coalesce(v_ev_emb, v_emb), 5, 0.6);
    return query select 'threshold_scales_agree', (v_n > 0 and v_distinct > 0),
      format('at the shared 0.6 default: findings %s rows, evidence %s rows', v_n, v_distinct);
  exception when others then return query select 'threshold_scales_agree', false, sqlerrm; end;

  begin
    if v_ev_emb is null then
      return query select 'evidence_limit_counts_distinct', true, 'skipped: no linked evidence';
      return query select 'evidence_linkage_preserved', true, 'skipped: no linked evidence';
    else
      select count(*), count(distinct s.evidence_id) into v_n, v_distinct
        from muster.q_search_evidence(v_ev_site, v_ev_emb, 6, 0) s;
      return query select 'evidence_limit_counts_distinct', v_n = v_distinct,
        format('%s rows for %s distinct evidence ids', v_n, v_distinct);

      select count(*) into v_bad from muster.q_search_evidence(v_ev_site, v_ev_emb, 6, 0) s
       where s.finding_ids is null or cardinality(s.finding_ids) = 0;
      return query select 'evidence_linkage_preserved', v_bad = 0,
        format('%s row(s) lost their finding linkage', v_bad);
    end if;
  exception when others then return query select 'evidence_limit_counts_distinct', false, sqlerrm; end;

  begin
    perform public.muster_engine_search_findings(
      jsonb_build_object('scopes', jsonb_build_array('read'), 'organization_id', v_org + 999999),
      v_site, v_emb, 1, 0);
    return query select 'org_scope_denies_mismatch', false, 'a mismatched organization_id was NOT denied';
  exception
    when sqlstate '42501' then return query select 'org_scope_denies_mismatch', true, 'denied as expected';
    when others then return query select 'org_scope_denies_mismatch', false, sqlerrm;
  end;

  begin
    perform public.muster_engine_search_findings(
      jsonb_build_object('scopes', jsonb_build_array('read')),
      v_site, v_emb, 1, 0);
    return query select 'org_scope_denies_missing_org', false,
      'ctx with no organization_id was NOT denied: the check fails open, so any caller reaching this function reads unscoped';
  exception
    when sqlstate '42501' then return query select 'org_scope_denies_missing_org', true, 'denied as expected';
    when others then return query select 'org_scope_denies_missing_org', false, sqlerrm;
  end;

  begin
    select (select count(*) from muster.findings) - (select count(*) from muster.finding_embeddings)
         + (select count(*) from muster.scan_evidence) - (select count(*) from muster.evidence_embeddings)
      into v_bad;
    return query select 'embeddings_complete', v_bad = 0, format('%s record(s) unembedded', v_bad);
  exception when others then return query select 'embeddings_complete', false, sqlerrm; end;
end;
$fn$;

revoke all on function muster.test_retrieval_contract() from public, anon, authenticated;
