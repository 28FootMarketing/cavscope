-- The browser engine's results reach the report's data, not just its markdown.
--
-- Migration 20261005020553 added "## Browser Engine Results" to the SITREP markdown
-- (sitrep_browser_md, called from generate_sitrep) and nothing else. sections.browser
-- did not exist, the report template named no browser section, and neither /sitrep
-- nor the workspace reports drew one. The markdown and the viewer were different
-- documents again, which is the failure CLAUDE.md records for the SITREP: a section
-- added to one is added to all. The engine is dark today, so no customer report has a
-- browser section yet; this lands before any browser rule is switched on.
--
--   * cavscope.sitrep_browser_section(scan) returns the facts sitrep_browser_md prints
--     (engine, scan id, completed, pages, every check with its outcome, the
--     unauthorized-active-tests note), or null when no complete browser scan for the
--     site falls in the seven days before the scan being reported.
--   * generate_sitrep stores it as sections.browser (JSON null when absent).
--   * sitrep_report_model names 'browser' after 'top_findings' in both profiles, where
--     the markdown prints it. A page draws nothing for a null section.
--
-- (The header comments were added to this file after the statements were applied; the
-- statements are identical to what migration 20261011032759 ran.)
--
-- Both functions are edited in place, each replacement asserted to match exactly once,
-- and only if they are still the definitions read on 2026-10-11 (the md5 guard). The
-- $o$ ... $o$ / $n$ ... $n$ pairs are the whole change; tests/sitrep reads them.

create or replace function pg_temp.patch_once(s text, o text, n text) returns text
language plpgsql as $f$
begin
  if (length(s) - length(replace(s, o, ''))) <> length(o) then
    raise exception 'expected exactly one occurrence of: %', left(o, 80);
  end if;
  return replace(s, o, n);
end
$f$;

do $guard$
begin
  if md5(pg_get_functiondef('cavscope.generate_sitrep(bigint)'::regprocedure)) <> 'ea22414d5b6be9186121441e896aa431' then
    raise exception 'cavscope.generate_sitrep changed since this migration was written';
  end if;
  if md5(pg_get_functiondef('cavscope.sitrep_report_model(bigint,bigint,jsonb,jsonb)'::regprocedure)) <> '916b238c8b0688a7e911e861407ff47d' then
    raise exception 'cavscope.sitrep_report_model changed since this migration was written';
  end if;
end
$guard$;

create or replace function cavscope.sitrep_browser_section(p_scan_id bigint) returns jsonb
language plpgsql stable security definer set search_path to ''
as $function$
declare
  b    cavscope.scans%rowtype;
  v_id bigint := cavscope.sitrep_browser_scan(p_scan_id);
begin
  if v_id is null then return null; end if;
  select * into b from cavscope.scans where id = v_id;
  return jsonb_build_object(
    'scan_id', b.id,
    'engine_version', coalesce(b.engine_version, 'browser'),
    'completed_at', b.finished_at,
    'pages_visited', b.summary->'pages_visited',
    'checks', (select coalesce(jsonb_agg(jsonb_build_object('rule_id', t.x->>'rule_id', 'outcome', t.x->>'outcome', 'detail', t.x->>'detail') order by t.n), '[]'::jsonb)
               from jsonb_array_elements(coalesce(b.summary->'browser_checks', '[]'::jsonb)) with ordinality as t(x, n)),
    'active_tests_unauthorized', coalesce((b.options->>'active_tests_requested')::boolean, false)
                                 and not coalesce((b.options->>'active_tests')::boolean, false));
end;
$function$;
revoke all on function cavscope.sitrep_browser_section(bigint) from public, anon, authenticated;

do $patch$
declare d text;
begin
  d := pg_get_functiondef('cavscope.generate_sitrep(bigint)'::regprocedure);
  d := pg_temp.patch_once(d, $o$  v_sections jsonb;
begin
$o$, $n$  v_sections jsonb;
  v_browser jsonb;
begin
$n$);
  d := pg_temp.patch_once(d, $o$  v_sections := jsonb_build_object(
      'scan',$o$, $n$  -- The browser engine's results for this site (null when there are none), stored as
  -- data so the viewer and the workspace draw the section the markdown prints.
  v_browser := cavscope.sitrep_browser_section(p_scan_id);

  v_sections := jsonb_build_object(
      'scan',$n$);
  d := pg_temp.patch_once(d, $o$      'jurisdiction', v_jur,
$o$, $n$      'browser', v_browser,
      'jurisdiction', v_jur,
$n$);
  execute d;

  d := pg_get_functiondef('cavscope.sitrep_report_model(bigint,bigint,jsonb,jsonb)'::regprocedure);
  d := pg_temp.patch_once(d, $o$jsonb_build_array('plain_english', 'top_findings', 'scope_note', 'jurisdiction')$o$,
                             $n$jsonb_build_array('plain_english', 'top_findings', 'browser', 'scope_note', 'jurisdiction')$n$);
  d := pg_temp.patch_once(d, $o$jsonb_build_array('board_report', 'metrics', 'controls', 'top_findings', 'scope_note', 'evidence_index')$o$,
                             $n$jsonb_build_array('board_report', 'metrics', 'controls', 'top_findings', 'browser', 'scope_note', 'evidence_index')$n$);
  execute d;
end
$patch$;

do $check$
begin
  if position('v_browser := cavscope.sitrep_browser_section(p_scan_id)' in pg_get_functiondef('cavscope.generate_sitrep(bigint)'::regprocedure)) = 0 then
    raise exception 'generate_sitrep does not store the browser section';
  end if;
  if (select count(*) from regexp_matches(pg_get_functiondef('cavscope.sitrep_report_model(bigint,bigint,jsonb,jsonb)'::regprocedure), '''top_findings'', ''browser''', 'g')) <> 2 then
    raise exception 'both report profiles must name the browser section after top_findings';
  end if;
end
$check$;
