-- TEMPORARY. Dropped by muster_031 in the same session.
--
-- The three auth.users rows (and their auth.identities rows) have to move from
-- mgtmqucaldkaxvxglguw to this project with their UUIDs intact:
-- muster.users.auth_user_id has no FK to auth.users, so the already-imported
-- muster.users rows bind correctly only if the UUIDs match exactly. Recreating
-- the accounts through the Auth Admin API would mint new UUIDs and orphan all
-- three.
--
-- Why an endpoint instead of an INSERT with literal values: the rows carry
-- bcrypt password hashes. Moving them server-to-server over pg_net keeps that
-- credential material out of any transcript, log or migration file. The same
-- reasoning produced muster_023 for the bulk data import.
--
-- auth.users.confirmed_at and auth.identities.email are GENERATED ALWAYS
-- columns, so `insert ... select *` fails. The column list is read from
-- information_schema at call time rather than typed out -- 35 hand-copied
-- column names is exactly the transcription risk that produced muster_016
-- and muster_017.
--
-- The token below is single-use and is dead the moment muster_031 drops this
-- function. Do not reuse the value.

create or replace function public.muster_auth_import(p_token text, p_users jsonb, p_identities jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $fn$
declare
  v_cols text;
  v_users int := 0;
  v_ids   int := 0;
begin
  if p_token is null or p_token <> '0525f35fcd034927ce8f6ca1c0414e6f09d3d2479bf6ea0b' then
    raise exception 'unauthorized';
  end if;

  select string_agg(quote_ident(column_name), ', ' order by ordinal_position)
    into v_cols
  from information_schema.columns
  where table_schema = 'auth' and table_name = 'users' and is_generated = 'NEVER';

  execute format(
    'insert into auth.users (%s) select %s from jsonb_populate_recordset(null::auth.users, $1) on conflict (id) do nothing',
    v_cols, v_cols) using p_users;
  get diagnostics v_users = row_count;

  select string_agg(quote_ident(column_name), ', ' order by ordinal_position)
    into v_cols
  from information_schema.columns
  where table_schema = 'auth' and table_name = 'identities' and is_generated = 'NEVER';

  execute format(
    'insert into auth.identities (%s) select %s from jsonb_populate_recordset(null::auth.identities, $1) on conflict (id) do nothing',
    v_cols, v_cols) using p_identities;
  get diagnostics v_ids = row_count;

  return jsonb_build_object('users', v_users, 'identities', v_ids);
end
$fn$;

revoke all on function public.muster_auth_import(text, jsonb, jsonb) from public;
grant execute on function public.muster_auth_import(text, jsonb, jsonb) to anon, authenticated, service_role;
