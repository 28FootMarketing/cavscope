-- muster_048: expose search_docs to the agent.
--
-- muster_047 built the corpus and the search. This is the half that makes it
-- reachable: without a tool entry the agent never learns the capability exists,
-- and retrieval that nothing can call is a table with rows in it.
--
-- agent_tools() is patched rather than rewritten. It is a 15-entry jsonb literal,
-- and restating all of it here to add one line is how two definitions of the same
-- catalog end up in the history disagreeing about which tools exist. The anchor is
-- asserted before the patch runs, so a drifted definition fails loudly instead of
-- being silently left unpatched.

do $do$
declare
  v_def text;
  v_anchor text := $anchor$    jsonb_build_object('name', 'get_evidence', 'scope', 'read',$anchor$;
  v_new text := $new$    jsonb_build_object('name', 'search_docs', 'scope', 'read',
      'description', 'Semantic search over MUSTER''s own documentation -- the scan rule catalog and how the product works. Use this to explain what a finding MEANS, what a rule checks, or why a severity is what it is, instead of inferring it from the finding text. Results carry doc_path, heading and anchor: cite them as docs/FILE.md#anchor so a human can open the source. Not tenant data and not scoped to a website.',
      'inputSchema', jsonb_build_object('type', 'object', 'required', jsonb_build_array('query'), 'properties', jsonb_build_object('query', jsonb_build_object('type', 'string', 'description', 'What you need explained, in your own words.'), 'limit', jsonb_build_object('type', 'integer', 'default', 8), 'threshold', jsonb_build_object('type', 'number', 'default', 0.5, 'description', 'Similarity threshold 0-1; lower = broader')))),
$new$;
begin
  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'muster' and p.proname = 'agent_tools';

  if v_def is null then
    raise exception 'muster.agent_tools() not found -- the tool catalog moved, patch by hand';
  end if;

  if position('''search_docs''' in v_def) > 0 then
    raise notice 'search_docs already in the catalog, nothing to patch';
    return;
  end if;

  if (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor) <> 1 then
    raise exception 'get_evidence anchor appears % time(s) in agent_tools(), expected exactly 1',
      (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
  end if;

  execute replace(v_def, v_anchor, v_new || v_anchor);
end
$do$;

-- The catalog is the contract the agent reads. Assert the patch took rather than
-- assume the replace matched.
do $$
declare v_names text[];
begin
  select array_agg(t->>'name' order by t->>'name') into v_names
  from jsonb_array_elements(muster.agent_tools()) t;

  if not ('search_docs' = any (v_names)) then
    raise exception 'search_docs is not in agent_tools() after patching; catalog is %', v_names;
  end if;

  if (select count(*) from jsonb_array_elements(muster.agent_tools()) t where t->>'name' = 'search_docs') <> 1 then
    raise exception 'search_docs appears more than once in agent_tools()';
  end if;

  -- Every tool still needs a schema; a malformed splice would show up here rather
  -- than as an MCP client rejecting tools/list in production.
  if exists (select 1 from jsonb_array_elements(muster.agent_tools()) t
             where t->'inputSchema' is null or t->>'description' is null or t->>'scope' is null) then
    raise exception 'agent_tools() has an entry missing description, scope or inputSchema after patching';
  end if;
end $$;
