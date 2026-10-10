-- Console Overview wiring pass (admin.html, Overview section).
--
-- Four defects in public.cavscope_admin_console(), each found by reading the payload
-- against the live catalog on 2026-10-10:
--   1. The cron list was filtered `like 'muster%'`, so cavscope-browser-sweep was never
--      monitored, and a rename of the other jobs would have left the list empty, which the
--      page rendered as "0 healthy". Now matches both prefixes.
--   2. Risk Watch listed the sandbox org's findings (70 open at this writing) as platform
--      risk while the High-Risk tile beside it excludes the sandbox. Now excluded.
--   3. The payload called the old public.muster_public_pricing() alias; dropping that alias
--      at stage 5 would have broken the whole console. Now calls the cavscope_ name.
--   4. system.billing is new: stuck paid checkouts, so the Billing Webhook row can report
--      what is observed instead of a fixed "Signature-verified". The action item for stuck
--      grants now excludes grants voided by a cancellation, as the watchdog does.
-- Each in-place edit must apply exactly once or the migration aborts.

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

  d := pg_temp.sub(d, 'where j.jobname like ''muster%'')),',
                      'where j.jobname like ''muster%'' or j.jobname like ''cavscope%'')),');
  d := pg_temp.sub(d, 'where f.status in (''open'', ''reopened'') and f.severity in (''critical'', ''high'', ''medium'')',
                      'where f.status in (''open'', ''reopened'') and f.severity in (''critical'', ''high'', ''medium'') and not o.is_admin_sandbox');
  d := pg_temp.sub(d, 'public.muster_public_pricing()', 'public.cavscope_public_pricing()');
  d := pg_temp.sub(d, 'Opened by muster-watchdog and not yet closed', 'Opened by cavscope-watchdog and not yet closed');
  d := pg_temp.sub(d, '(customer.subscription.deleted is unhandled)', '(cancellation is handled in code, not yet seen live)');
  d := pg_temp.sub(d, '''sent_24h'', (select count(*) from cavscope.notification_outbox where status = ''sent'' and sent_at > now() - interval ''24 hours'')),',
                      '''sent_24h'', (select count(*) from cavscope.notification_outbox where status = ''sent'' and sent_at > now() - interval ''24 hours'')),
      ''billing'', jsonb_build_object(
        ''stuck_grants'', (select count(*) from cavscope.pending_commercial_grants where applied_at is null and cancelled_at is null and created_at < now() - interval ''24 hours''),
        ''last_grant_at'', (select max(created_at) from cavscope.pending_commercial_grants)),');
  d := pg_temp.sub(d, 'where applied_at is null and created_at < now() - interval ''24 hours''),
          ''Paid checkouts',
                      'where applied_at is null and cancelled_at is null and created_at < now() - interval ''24 hours''),
          ''Paid checkouts');

  execute d;
end $mig$;
