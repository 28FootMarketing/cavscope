-- muster_045: rebuild the control register at the end of every ingest.
--
-- muster_044 made muster.controls a projection of findings. A projection that
-- is only refreshed by hand is the same stale table it replaced, so the sync
-- runs where the findings are written: muster.engine_ingest, the function
-- behind the public.muster_engine_ingest RPC the scanner calls.
--
-- It goes immediately after the posture score, on the same principle: both read
-- the finding set that ingest has just finished writing, so both have to run
-- once that write is complete rather than partway through it.
--
-- Failure here must not fail the scan. A control register one scan stale is
-- cosmetic; a scan that reports "ingest failed" because a summary table could
-- not be rebuilt loses the findings, the evidence and the SITREP with it. The
-- exception is swallowed into an activity event so it stays visible without
-- being fatal.
--
-- The patch is applied by rewriting the function definition rather than
-- restating it, so this migration cannot silently revert an unrelated change
-- someone else made to engine_ingest. It asserts the anchor exists first and
-- asserts the call is present afterwards.

create or replace function muster.do_ingest_controls(p_website_id bigint, p_org_id bigint)
returns void
language plpgsql security definer set search_path to '' as $function$
begin
  perform muster.sync_controls(p_website_id);
exception when others then
  insert into muster.activity_events (organization_id, entity_type, entity_id, action, detail)
  values (p_org_id, 'website', p_website_id, 'Control register refresh failed', left(SQLERRM, 500));
end;
$function$;

revoke all on function muster.do_ingest_controls(bigint, bigint) from public;

do $$
declare
  v_oid oid;
  v_src text;
  v_def text;
begin
  select p.oid into v_oid from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'muster' and p.proname = 'engine_ingest';

  if v_oid is null then
    raise exception 'muster.engine_ingest not found';
  end if;

  select prosrc into v_src from pg_proc where oid = v_oid;

  if position('do_ingest_controls' in v_src) > 0 then
    raise notice 'engine_ingest already calls do_ingest_controls; nothing to do';
    return;
  end if;
  if position('v_score := muster.posture_score(v_scan.website_id);' in v_src) = 0 then
    raise exception 'engine_ingest no longer computes the posture score where expected; do not patch blindly';
  end if;

  v_def := pg_get_functiondef(v_oid);
  execute replace(
    v_def,
    '  v_score := muster.posture_score(v_scan.website_id);',
    '  v_score := muster.posture_score(v_scan.website_id);' || chr(10) ||
    '  perform muster.do_ingest_controls(v_scan.website_id, v_scan.organization_id);'
  );
end $$;

do $$
declare
  v_src text;
begin
  select prosrc into v_src from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'muster' and p.proname = 'engine_ingest';
  if position('do_ingest_controls' in v_src) = 0 then
    raise exception 'the engine_ingest patch did not take';
  end if;
  -- The posture score must still be computed; the patch adds a line, it does
  -- not replace one.
  if position('v_score := muster.posture_score(v_scan.website_id);' in v_src) = 0 then
    raise exception 'the patch removed the posture score computation';
  end if;
end $$;
