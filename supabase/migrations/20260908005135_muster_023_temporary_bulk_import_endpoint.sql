-- TEMPORARY. Exists only to move 653 rows from mgtmqucaldkaxvxglguw into this
-- project without routing 300 KB of tenant data through a chat transcript.
-- The source project has pg_net; this is the endpoint it POSTs to.
--
-- THIS IS A WRITE PATH REACHABLE BY anon AND IT MUST BE DROPPED WHEN THE DATA
-- LANDS. It is gated on a 40-character token that exists only for this
-- migration, it can only touch base tables in the muster schema, and it is
-- on a project with no production traffic and no auth users yet. Those are
-- mitigations, not a reason to leave it in place. muster_024 drops it.
--
-- on conflict do nothing makes each call idempotent, so a retried or duplicated
-- POST cannot double-insert. pg_net is fire-and-forget, so retries are likely.
create or replace function public.muster_bulk_import(p_token text, p_table text, p_rows jsonb)
returns integer
language plpgsql
security definer
set search_path to 'pg_catalog'
as $function$
declare
  v_expected constant text := 'mstr_imp_9f3a7c1e5b2d84a60e7f1c93b5d8a42f';
  v_always boolean;
  v_n integer;
begin
  if p_token is distinct from v_expected then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  if not exists (
    select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'muster' and c.relkind = 'r' and c.relname = p_table
  ) then
    raise exception 'unknown table %', p_table using errcode = '22023';
  end if;

  -- Four tables (change_events, incidents, notification_outbox,
  -- pending_commercial_grants) have GENERATED ALWAYS identity columns, which
  -- reject an explicit id without this clause. The rest reject the clause.
  select exists (
    select 1 from pg_attribute a
    join pg_class c on c.oid = a.attrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'muster' and c.relname = p_table and a.attidentity = 'a'
  ) into v_always;

  execute format(
    'insert into muster.%I %s select * from jsonb_populate_recordset(null::muster.%I, $1) on conflict do nothing',
    p_table,
    case when v_always then 'overriding system value' else '' end,
    p_table)
  using p_rows;

  get diagnostics v_n = row_count;
  return v_n;
end
$function$;

revoke all on function public.muster_bulk_import(text, text, jsonb) from public;
grant execute on function public.muster_bulk_import(text, text, jsonb) to anon, service_role;
