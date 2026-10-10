-- Integrations wiring pass (admin.html).
--
-- The Integrations section said "each row is inferred from real rows" while two of its four rows
-- were fixed text (and one of them, "subscription.deleted: not handled", has been false since
-- 2026-10-01). The console payload now returns what the database can actually observe about each
-- outbound dependency, as `integrations`: Stripe grants (recorded, claimed, cancelled), Resend
-- delivery events and suppressions, inbound mail routes and forwards, support requests (and
-- whether AI triage ran), tenant LLM configurations and their errors, and the browser engine's
-- scans. The page renders each row from these counts. The edit must apply exactly once or the
-- migration aborts.

create or replace function pg_temp.sub(src text, old text, new text) returns text
language plpgsql as $f$
declare n int;
begin
  n := (length(src) - length(replace(src, old, ''))) / length(old);
  if n <> 1 then raise exception 'expected exactly 1 match, found % for: %', n, left(old, 80); end if;
  return replace(src, old, new);
end $f$;

do $mig$
declare d text;
begin
  select pg_get_functiondef(p.oid) into d
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'cavscope_admin_console';

  d := pg_temp.sub(d, '    ''pricing_changes'', (select coalesce(',
    '    ''integrations'', jsonb_build_object(
      ''stripe'', (select jsonb_build_object(
          ''grants'', count(*),
          ''last_grant_at'', max(g.created_at),
          ''claimed'', count(*) filter (where g.applied_at is not null),
          ''cancelled'', count(*) filter (where g.cancelled_at is not null))
        from cavscope.pending_commercial_grants g),
      ''email'', jsonb_build_object(
        ''last_sent_at'', (select max(sent_at) from cavscope.notification_outbox where status = ''sent''),
        ''events'', (select count(*) from cavscope.email_events),
        ''last_event_at'', (select max(created_at) from cavscope.email_events),
        ''suppressed'', (select count(*) from cavscope.email_suppressions)),
      ''inbound'', jsonb_build_object(
        ''routes'', (select count(*) from cavscope.mail_routes),
        ''forwarded'', (select count(*) from cavscope.mail_forwards where status = ''sent''),
        ''failed'', (select count(*) from cavscope.mail_forwards where status <> ''sent''),
        ''last_forward_at'', (select max(created_at) from cavscope.mail_forwards)),
      ''support'', jsonb_build_object(
        ''requests'', (select count(*) from cavscope.support_requests),
        ''failed'', (select count(*) from cavscope.support_requests where status = ''failed''),
        ''last_at'', (select max(created_at) from cavscope.support_requests),
        ''ai_done'', (select count(*) from cavscope.support_requests where ai_status is not null)),
      ''tenant_llms'', jsonb_build_object(
        ''configured'', (select count(*) from cavscope.org_llm_config where enabled),
        ''erroring'', (select count(*) from cavscope.org_llm_config where enabled and last_error_at is not null
                         and (last_ok_at is null or last_error_at > last_ok_at))),
      ''browser'', jsonb_build_object(
        ''scans'', (select count(*) from cavscope.scans where engine = ''browser''),
        ''last_at'', (select max(coalesce(finished_at, created_at)) from cavscope.scans where engine = ''browser''))),

    ''pricing_changes'', (select coalesce(');
  execute d;
end $mig$;
