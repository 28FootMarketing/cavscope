-- MUSTER 088: an audit log for the scan-rule catalog's own lifecycle --
-- created, activated, deactivated, retired -- separate from muster.scans,
-- which audits what a SCAN did, not what happened to the RULES themselves.
--
-- WHY THIS EXISTS
--
-- Every activation and hold up to this point (SEC-014/015/EMAIL-008,
-- AVAIL-003/004, EMAIL-009, AUTH-001..006, and this session's own SEC-016..020)
-- is real history, but it lives only in migration file prose. That is fine for
-- a developer reading git log; it is invisible to anyone using the product,
-- including a super admin who wants to know why a rule stopped firing, and it
-- depends on nobody ever applying a change outside this repo. Both failure
-- modes are not hypothetical: this same migration recovers five scan-rule-
-- relevant changes (GOV-006..008, the five ai_governance rules, two
-- jurisdiction seeds) that were applied straight to hjowfnzpomzxazmzywxw with
-- no file here at all -- see supabase/migrations/README.md. A queryable table
-- does not depend on every future change going through this directory; it
-- depends on the table, which is a much smaller thing to keep correct.
--
-- WHY A SEPARATE TABLE, NOT muster.activity_events
--
-- activity_events requires organization_id not null: it audits what a
-- tenant's users did inside their own org. A scan rule's lifecycle has no
-- organization -- it is platform-wide, the same rule for every tenant -- so
-- forcing a fake organization_id onto it would be exactly the kind of
-- dishonest modeling this project keeps finding and fixing elsewhere (the
-- framework CHECK constraint, the white-label flag key that never existed).
--
-- WHY NO FOREIGN KEY TO scan_rules
--
-- The one job this table has is to survive the row it is about. rule_id is a
-- plain text column, not a reference to scan_rules(rule_id): if a rule is
-- ever genuinely deleted (findings.rule_id's own FK to scan_rules already
-- makes that impossible for any rule that has fired even once, without
-- CASCADE, which nothing here specifies), the history of what it was and why
-- it went away must not disappear with it. An audit log with a hard
-- dependency on the thing it audits is not an audit log.
--
-- retired_at / retired_reason vs. plain active = false
--
-- Every rule before this migration has exactly one state for "not running":
-- active = false, which means both "held pending engine work, will activate"
-- (SEC-014 in 2026-09 for three weeks) and "will never run from this engine"
-- (SEC-019, this session -- fetch() cannot send TRACE; see index.ts's
-- ENGINE_VERSION comment). Those are different facts and a console cannot
-- tell them apart from active alone. retired_at is null for the first kind
-- and set for the second; a CHECK constraint ties it to retired_reason so a
-- retirement can never be recorded with no explanation of why.
--
-- WHAT THE TRIGGER DOES AND DOES NOT CAPTURE
--
-- It fires on every insert and on every update that changes active or sets
-- retired_at, and infers created/activated/deactivated/retired from the
-- transition -- so a future migration that simply does the same
-- insert/update it always has gets an audit row for free, with no new
-- discipline required of whoever writes it. It does NOT fire on an ordinary
-- content edit (a fixed typo in remediation text, a reworded plain_english
-- line): that is not a lifecycle event, and logging every such edit would
-- bury the transitions that matter in noise.
--
-- WHY reason CAN BE A PLACEHOLDER, NOT WHY IT SHOULD BE
--
-- reason is NOT NULL, filled from current_setting('muster.rule_change_reason',
-- true) and falling back to an honest "(no reason recorded...)" string when
-- nothing set it. The fallback exists so a change is never silently lost for
-- want of one extra line; it is not permission to skip that line.
--
-- HOW REASON ACTUALLY GETS SET, AND WHY NOT set_config ALONE
--
-- The first version of this migration set the reason with a bare
-- `select set_config('muster.rule_change_reason', ..., true)` as its own
-- statement, immediately before the `update` that should have picked it up --
-- and it did not, in a local Postgres 16 test of this exact file. `true`
-- scopes a GUC to the CURRENT TRANSACTION, and this repo's own migrations
-- have never assumed a whole file runs as one transaction (084's own
-- assertion blocks are `do $$ ... $$` bodies precisely because a bare `select`
-- cannot roll a prior statement back on failure). Whether apply_migration
-- happens to send a whole file as one implicit transaction is not something
-- to build a correctness guarantee on when it was never verified either way.
--
-- So the reason-setting and the row change are done inside ONE function call
-- instead: muster.scan_rule_retire() and muster.scan_rule_set_active() below
-- both `perform set_config(...)` and then run their own `update`, in the same
-- plpgsql function body, which is atomic with respect to the caller no matter
-- how the caller's statements are batched. Every future migration that
-- retires or (de)activates a rule should call one of these two, not touch
-- `scan_rules.active` or `retired_at` directly. A plain multi-row `insert`
-- for a brand-new rule is unchanged -- that convention predates this
-- migration and stays -- so a 'created' history row records the honest
-- fallback reason unless a future change also wraps creation in a helper.

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

-- Atomic wrappers: set the reason context and make the change in one function
-- call, so the two can never end up in different transactions. See the header
-- note above for why a bare set_config() followed by a separate update is not
-- safe to rely on here.
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
      return new; -- a content edit, not a lifecycle transition
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

-- Super-admin-facing read, matching every other muster_admin_* RPC's shape and
-- grants exactly (see muster_068's muster_admin_platform_extras for the
-- pattern this copies). This is engine/catalog metadata, not tenant data.
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

-- First real use: SEC-019 is retired for real, not just in a code comment.
-- fetch() throws "Method is forbidden" for TRACE/TRACK/CONNECT -- confirmed
-- against Deno 2.9.7, and it is the WHATWG Fetch spec's own forbidden-method
-- list, so no spec-compliant fetch() can ever send one. This engine's egress
-- is fetch()-only (see index.ts's ENGINE_VERSION comment for why), so there is
-- no path to activation without a transport this engine does not have.
select muster.scan_rule_retire(
  'SEC-019',
  'fetch() cannot send TRACE/TRACK/CONNECT (WHATWG Fetch spec forbidden-method list, confirmed against Deno 2.9.7); this engine has no raw-socket fallback. No path to activation without a different transport.',
  'http-native-1.9.0',
  '20260923210000_muster_088_scan_rule_lifecycle_audit'
);

-- Assertions: schema shape, grants, the trigger actually fired for SEC-019,
-- and the admin RPC enforces super-admin the same way its siblings do.
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

  -- The retirement-reason CHECK must actually hold both directions.
  begin
    update muster.scan_rules set retired_at = now() where rule_id = 'AUTH-006';
    raise exception 'scan_rules_retirement_reason_check did not reject retired_at with no retired_reason';
  exception when check_violation then
    null; -- expected
  end;

  raise notice 'scan_rule_history live: % row(s) for SEC-019, admin RPC grants correct, retirement CHECK enforced', v_history_rows;
end $$;
