-- Adds no_stale_embeddings to the retrieval contract.
--
-- embeddings_complete only ever asked "does every row have an embedding". It
-- passed 11/11 while 4 of 13 findings carried embeddings older than their own
-- last content change -- present, but generated from text that no longer
-- matched. Search was answering from stale vectors and every existing check
-- was green.
--
-- This is the regression test for that gap. It fails if any embedding predates
-- its source row's last update, which the queue wiring
-- (muster_wire_up_embedding_queue) now resolves within one 15-minute cycle.

create or replace function muster.test_retrieval_contract()
returns table(test text, passed boolean, detail text)
language plpgsql
set search_path = public, muster, pg_temp
as $fn$
declare
  v_site bigint; v_org bigint; v_emb public.vector;
  v_ev_site bigint; v_ev_emb public.vector;
  v_n int; v_distinct int; v_sim double precision; v_bad int;
  v_unscoped boolean; v_reachable boolean;
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
    begin
      perform public.muster_engine_search_findings(
        jsonb_build_object('scopes', jsonb_build_array('read')), v_site, v_emb, 1, 0);
      v_unscoped := true;
    exception when sqlstate '42501' then
      v_unscoped := false;
    end;

    select bool_or(has_function_privilege('anon', p.oid, 'EXECUTE')
                or has_function_privilege('authenticated', p.oid, 'EXECUTE'))
      into v_reachable
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('muster_engine_search_findings','muster_engine_search_evidence');

    return query select 'platform_key_affordance_is_grant_gated',
      (not v_reachable),
      case
        when v_reachable and v_unscoped then
          'UNSAFE: a null-org context reads unscoped AND anon/authenticated can execute -- this is the cross-tenant exposure fixed in 20260907083752'
        when v_reachable then
          'UNSAFE: anon/authenticated can execute the search wrappers'
        when v_unscoped then
          'safe: null-org context reads unscoped (platform key, by design) and only service_role can execute'
        else
          'safe: null-org context is denied and only service_role can execute (stricter than agent_call)'
      end;
  exception when others then
    return query select 'platform_key_affordance_is_grant_gated', false, sqlerrm;
  end;

  begin
    select (select count(*) from muster.findings) - (select count(*) from muster.finding_embeddings)
         + (select count(*) from muster.scan_evidence) - (select count(*) from muster.evidence_embeddings)
      into v_bad;
    return query select 'embeddings_complete', v_bad = 0, format('%s record(s) unembedded', v_bad);
  exception when others then return query select 'embeddings_complete', false, sqlerrm; end;

  -- Present is not the same as current. An edited finding keeps its old vector,
  -- so embeddings_complete stays green while search answers from text that no
  -- longer exists. Measured 4 of 13 stale before the queue was wired up.
  begin
    select count(*) into v_bad
      from muster.findings f
      join muster.finding_embeddings fe on fe.finding_id = f.id
     where f.updated_at > fe.created_at;
    select v_bad + count(*) into v_bad
      from muster.embedding_queue q
     where q.processed_at is null
       and q.created_at < now() - interval '45 minutes';
    return query select 'no_stale_embeddings', v_bad = 0,
      case when v_bad = 0
           then 'no embedding older than its source, nothing queued beyond 3 drain cycles'
           else format('%s stale embedding(s) or queue rows older than 45 minutes', v_bad) end;
  exception when others then return query select 'no_stale_embeddings', false, sqlerrm; end;
end;
$fn$;

revoke all on function muster.test_retrieval_contract() from public, anon, authenticated;
