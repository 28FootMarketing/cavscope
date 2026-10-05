-- Browser engine, phase 1b: two read-side pieces the worker and the report need.
--
-- 1. cavscope_engine_open_browser_findings: the browser findings currently open on a site. The worker
--    uses it for the disappearance rule: a finding that vanishes is confirmed by one fresh-cache re-run
--    before it can count as fixed, because a transient load failure looks exactly like a fix.
-- 2. OPS-002: "DNS is managed at <provider>" on the fix text of DNS-type findings, from the NS evidence
--    a browser scan records. It is a note on the REPORT, not a stored change to the rule's text, and it
--    appears only once a browser scan has read the site's NS records. The HTTP engine does not record
--    them, and teaching it to would move http-native's ENGINE_VERSION for a report convenience.

create or replace function public.cavscope_engine_open_browser_findings(p_website_id bigint)
returns table (rule_id text, location text)
language sql stable security definer set search_path to ''
as $$
  select f.rule_id::text, f.location::text
    from cavscope.findings f
    join cavscope.scan_rules r on r.rule_id = f.rule_id
   where f.website_id = p_website_id and r.check_type = 'browser' and f.status in ('open', 'reopened')
$$;
revoke all on function public.cavscope_engine_open_browser_findings(bigint) from public, anon, authenticated;
grant execute on function public.cavscope_engine_open_browser_findings(bigint) to service_role;

create or replace function cavscope.dns_fix_note(p_website_id bigint, p_rule_id text) returns text
language plpgsql stable security definer set search_path to ''
as $$
declare v_excerpt text; v_providers jsonb;
begin
  if not (p_rule_id like 'EMAIL-%' or p_rule_id in ('SEC-015', 'SEC-020')) then return ''; end if;
  select e.excerpt into v_excerpt
    from cavscope.scan_evidence e
   where e.website_id = p_website_id and e.kind = 'dns_ns'
   order by e.id desc limit 1;
  if v_excerpt is null then return ''; end if;
  begin
    v_providers := (v_excerpt::jsonb)->'provider';
  exception when others then
    return '';
  end;
  if v_providers is null or jsonb_typeof(v_providers) <> 'array' or jsonb_array_length(v_providers) = 0 then return ''; end if;
  return ' DNS for this domain is managed at ' ||
    (select string_agg(x, ' and ') from jsonb_array_elements_text(v_providers) x) ||
    ', so make this change there.';
end;
$$;
revoke all on function cavscope.dns_fix_note(bigint, text) from public, anon, authenticated;

do $$
declare d text;
begin
  create or replace function pg_temp.sub(src text, find text, repl text) returns text language plpgsql as $f$
  begin
    if position(find in src) = 0 then raise exception 'pattern not found: %', left(find, 90); end if;
    if position(find in substr(src, position(find in src) + length(find))) > 0 then raise exception 'pattern not unique: %', left(find, 90); end if;
    return replace(src, find, repl);
  end $f$;
  d := pg_get_functiondef('cavscope.generate_sitrep(bigint)'::regprocedure);
  d := pg_temp.sub(d, $q$r.remediation, r.plain_english, r.framework_refs,$q$,
                      $q$r.remediation || cavscope.dns_fix_note(fi.website_id, r.rule_id) as remediation, r.plain_english, r.framework_refs,$q$);
  execute d;
end $$;
