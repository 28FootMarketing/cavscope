alter table muster.scan_rules
  add column retired_at timestamptz,
  add column retired_reason text;

alter table muster.scan_rules
  add constraint scan_rules_retirement_reason_check
  check ((retired_at is null) = (retired_reason is null));

create table muster.scan_rule_history (
  id               bigserial primary key,
  rule_id          text not null,
  action           varchar(20) not null check (action in ('created', 'activated', 'deactivated', 'retired')),
  previous_active  boolean,
  new_active       boolean not null,
  reason           text not null,
  engine_version   text,
  migration_ref    text,
  created_at       timestamptz not null default now()
);

comment on table muster.scan_rule_history is
  'Append-only lifecycle log for muster.scan_rules: every created/activated/deactivated/retired transition, with why. No foreign key to scan_rules on purpose -- this table has to survive even if a rule row is ever deleted, or it fails at the one job it has.';

create index scan_rule_history_rule_id_idx on muster.scan_rule_history (rule_id, created_at desc);

revoke all on muster.scan_rule_history from public, anon, authenticated;
grant select, insert on muster.scan_rule_history to service_role;
grant usage on sequence muster.scan_rule_history_id_seq to service_role;

create or replace function muster.scan_rule_set_active(p_rule_id text, p_active boolean, p_reason text, p_engine_version text default null, p_migration_ref text default null)
returns void
language plpgsql
as $function$
begin
  perform set_config('muster.rule_change_reason', p_reason, true);
  perform set_config('muster.rule_change_engine_version', coalesce(p_engine_version, ''), true);
  perform set_config('muster.rule_change_migration_ref', coalesce(p_migration_ref, ''), true);
  update muster.scan_rules set active = p_active, updated_at = now() where rule_id = p_rule_id;
  if not found then raise exception 'no scan_rules row for %', p_rule_id; end if;
end;
$function$;

create or replace function muster.scan_rule_retire(p_rule_id text, p_reason text, p_engine_version text default null, p_migration_ref text default null)
returns void
language plpgsql
as $function$
begin
  perform set_config('muster.rule_change_reason', p_reason, true);
  perform set_config('muster.rule_change_engine_version', coalesce(p_engine_version, ''), true);
  perform set_config('muster.rule_change_migration_ref', coalesce(p_migration_ref, ''), true);
  update muster.scan_rules set retired_at = now(), retired_reason = p_reason where rule_id = p_rule_id;
  if not found then raise exception 'no scan_rules row for %', p_rule_id; end if;
end;
$function$;

create or replace function muster.log_scan_rule_change()
returns trigger
language plpgsql
as $function$
declare
  v_action text;
begin
  if tg_op = 'INSERT' then
    v_action := 'created';
  elsif tg_op = 'UPDATE' then
    if new.retired_at is not null and old.retired_at is null then
      v_action := 'retired';
    elsif new.active and not old.active then
      v_action := 'activated';
    elsif not new.active and old.active then
      v_action := 'deactivated';
    else
      return new;
    end if;
  else
    return new;
  end if;

  insert into muster.scan_rule_history (rule_id, action, previous_active, new_active, reason, engine_version, migration_ref)
  values (
    new.rule_id, v_action,
    case when tg_op = 'INSERT' then null else old.active end,
    new.active,
    coalesce(nullif(current_setting('muster.rule_change_reason', true), ''),
      '(no reason recorded by the migration or caller that made this change)'),
    nullif(current_setting('muster.rule_change_engine_version', true), ''),
    nullif(current_setting('muster.rule_change_migration_ref', true), '')
  );
  return new;
end;
$function$;

create trigger scan_rules_log_lifecycle
  after insert or update on muster.scan_rules
  for each row execute function muster.log_scan_rule_change();

create or replace function public.muster_admin_rule_history(p_rule_id text default null)
returns jsonb
language plpgsql
stable security definer
set search_path to ''
as $function$
begin
  if not muster.is_super_admin() then raise exception 'forbidden' using errcode = '42501'; end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', h.id, 'rule_id', h.rule_id, 'action', h.action,
      'previous_active', h.previous_active, 'new_active', h.new_active,
      'reason', h.reason, 'engine_version', h.engine_version,
      'migration_ref', h.migration_ref, 'created_at', h.created_at
    ) order by h.created_at desc, h.id desc)
    from muster.scan_rule_history h
    where p_rule_id is null or h.rule_id = p_rule_id
  ), '[]'::jsonb);
end;
$function$;

comment on function public.muster_admin_rule_history(text) is
  'Lifecycle history for one scan rule, or every rule when p_rule_id is null: every created/activated/deactivated/retired transition and why. Super admin only.';

revoke all on function public.muster_admin_rule_history(text) from public, anon;
grant execute on function public.muster_admin_rule_history(text) to authenticated, service_role;

select muster.scan_rule_retire(
  'SEC-019',
  'fetch() cannot send TRACE/TRACK/CONNECT (WHATWG Fetch spec forbidden-method list, confirmed against Deno 2.9.7); this engine has no raw-socket fallback. No path to activation without a different transport.',
  'http-native-1.9.0',
  '20260923210000_muster_088_scan_rule_lifecycle_audit'
);

do $$
declare
  v_history_rows int;
  v_action text;
  v_acl text;
begin
  select count(*), max(action) into v_history_rows, v_action
    from muster.scan_rule_history where rule_id = 'SEC-019';
  if v_history_rows <> 1 or v_action <> 'retired' then
    raise exception 'expected exactly one retired history row for SEC-019, found % (last action %)', v_history_rows, v_action;
  end if;

  if (select retired_at from muster.scan_rules where rule_id = 'SEC-019') is null then
    raise exception 'SEC-019.retired_at was not set';
  end if;

  select coalesce(array_to_string(p.proacl, ','), '') into v_acl
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'muster_admin_rule_history';
  if v_acl like '%anon=%' then
    raise exception 'anon can still execute muster_admin_rule_history: %', v_acl;
  end if;
  if v_acl not like '%authenticated=X%' then
    raise exception 'authenticated cannot execute muster_admin_rule_history: %', v_acl;
  end if;

  begin
    update muster.scan_rules set retired_at = now() where rule_id = 'AUTH-006';
    raise exception 'scan_rules_retirement_reason_check did not reject retired_at with no retired_reason';
  exception when check_violation then
    null;
  end;

  raise notice 'scan_rule_history live: % row(s) for SEC-019, admin RPC grants correct, retirement CHECK enforced', v_history_rows;
end $$;
