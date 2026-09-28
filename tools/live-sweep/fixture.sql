-- Builds the live-sweep fixture for one website from the live project.
-- Run it through the Supabase MCP (execute_sql) against hjowfnzpomzxazmzywxw,
-- replacing :website_id, and save the single `j` value as
-- tools/live-sweep/fixture.local.json. That file is gitignored: it is a real
-- tenant's findings, risks and evidence, and must never be committed.
--
-- Arrays are trimmed so the fixture stays small; every object keeps the exact
-- shape production returns, which is the point -- the #167 tiles were tested
-- against an assumed shape and shipped reading a field production never sends.
with p as (select :website_id::bigint as wid),
w as (select w.id, w.organization_id as oid from cavscope.websites w, p where w.id = p.wid),
ov as (select cavscope.q_website_overview((select id from w)) v),
org as (select cavscope.q_organization((select oid from w)) v),
st as (select cavscope.q_latest_sitrep((select id from w)) v)
select jsonb_build_object(
 'overview', (select v - 'findings' - 'compliance' - 'recent_scans'
    || jsonb_build_object('findings', (select jsonb_agg(f) from (select f from jsonb_array_elements(v->'findings') f limit 4) s),
                          'compliance', (v->'compliance') - 'laws' || jsonb_build_object('laws', (select jsonb_agg(l) from (select l from jsonb_array_elements(v->'compliance'->'laws') l limit 4) s)),
                          'recent_scans', (select jsonb_agg(r) from (select r from jsonb_array_elements(v->'recent_scans') r limit 3) s)) from ov),
 'org', (select v - 'advisory' - 'websites' - 'agents'
    || jsonb_build_object('websites', jsonb_build_array(v->'websites'->0), 'agents', coalesce(jsonb_build_array(v->'agents'->0), '[]'), 'advisory', (v->'advisory') - 'laws') from org),
 'sitrep', (select (v - 'sections' - 'content_md' - 'citations') || jsonb_build_object('content_md', left(v->>'content_md', 400), 'citations', '[]'::jsonb,
    'sections', (v->'sections') - 'jurisdiction' - 'top_findings' - 'evidence_index'
      || jsonb_build_object('jurisdiction', (v->'sections'->'jurisdiction') - 'laws' || jsonb_build_object('laws', (select jsonb_agg(l) from (select l from jsonb_array_elements(v->'sections'->'jurisdiction'->'laws') l limit 3) s)),
                            'top_findings', (select jsonb_agg(f) from (select f from jsonb_array_elements(v->'sections'->'top_findings') f limit 3) s),
                            'evidence_index', (select jsonb_agg(e) from (select e from jsonb_array_elements(v->'sections'->'evidence_index') e limit 4) s))) from st),
 'risks', (select jsonb_agg(to_jsonb(r) - 'description' - 'treatment_plan' || jsonb_build_object('owner_name', null, 'remediation_actions',
     (select coalesce(jsonb_agg(to_jsonb(a)), '[]') from cavscope.remediation_actions a where a.risk_id = r.id))) from cavscope.risks r, w where r.website_id = w.id),
 'appetite', (select to_jsonb(ra) from cavscope.risk_appetites ra, w where ra.organization_id = w.oid),
 'rules', (select jsonb_object_agg(rule_id, active) from cavscope.scan_rules)
)::text as j;
