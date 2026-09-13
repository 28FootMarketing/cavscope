-- Two operational defects found by a health sweep on 2026-09-13.
--
-- 1. public.muster_engine_record_email_event and public.muster_engine_resolve_alert
--    were executable by anon and authenticated. Every other muster_engine_* function
--    is service_role only, and these two are no exception in intent: their only
--    callers are muster-resend-webhook and muster-alert-dispatch, both of which
--    construct their client with SUPABASE_SERVICE_ROLE_KEY. No page calls either.
--
--    The grants were exploitable rather than merely untidy. The publishable key is
--    in page source by design, so anyone could POST to
--    /rest/v1/rpc/muster_engine_resolve_alert and mark a pending notification_outbox
--    row 'sent' -- silently suppressing a real HIGH-risk alert before it was ever
--    emailed -- or forge delivery and bounce events through record_email_event and
--    poison the suppression list.
--
-- 2. The watchdog could open an incident but nothing could ever close one. Its
--    engine_error_spike fingerprint is date-scoped (engine_error_spike:<today>)
--    while the underlying check is a rolling 24-hour window, so the condition
--    clearing can never reach yesterday's row. One failed scan on 2026-09-08
--    produced two permanently-open incidents and 144 dedupe bumps. Left alone,
--    open incident count only ever grows and stops meaning anything, which costs
--    the self-heal system exactly the signal it exists to provide.

revoke execute on function public.muster_engine_record_email_event(text, text, text, timestamptz, text[], jsonb) from anon, authenticated;
revoke execute on function public.muster_engine_resolve_alert(bigint, text, text, text) from anon, authenticated;

-- Closes incidents of one source whose condition the caller has just observed to
-- be clear. Deliberately NOT a general "close anything" call: the source is the
-- unit, because the watchdog knows a whole check is clear, never that one
-- historical row is individually fine.
--
-- root_cause_classification is set to 'unresolved' rather than something more
-- flattering, because that is the truth. The condition cleared; nobody diagnosed
-- why it occurred. The evidence that it happened at all survives in muster.scans
-- and in the incident's own first_seen_at/last_seen_at -- closing an alarm is not
-- erasing the history it recorded.
create or replace function muster.close_cleared_incidents(p_source text, p_evidence jsonb default '{}'::jsonb)
returns integer
language plpgsql
security definer
set search_path = muster, public, pg_temp
as $$
declare
  v_closed integer;
begin
  update muster.incidents
     set status = 'closed',
         updated_at = now(),
         root_cause_classification = coalesce(root_cause_classification, 'unresolved'),
         recovery_action = coalesce(recovery_action, 'none taken; the condition cleared on its own'),
         recovery_result = coalesce(recovery_result, 'not_applicable'),
         closure_evidence = coalesce(closure_evidence, '{}'::jsonb) || p_evidence ||
                            jsonb_build_object('closed_by', 'muster-watchdog', 'closed_at', now())
   where source = p_source
     and status in ('open', 'investigating');
  get diagnostics v_closed = row_count;
  return v_closed;
end;
$$;

create or replace function public.muster_engine_close_cleared_incidents(p_source text, p_evidence jsonb default '{}'::jsonb)
returns integer
language sql
security definer
set search_path = muster, public, pg_temp
as $$ select muster.close_cleared_incidents(p_source, p_evidence); $$;

revoke all on function muster.close_cleared_incidents(text, jsonb) from public;
revoke all on function public.muster_engine_close_cleared_incidents(text, jsonb) from public;
grant execute on function public.muster_engine_close_cleared_incidents(text, jsonb) to service_role;