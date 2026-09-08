-- muster_037: email delivery tracking and suppression.
--
-- Before this, muster-alert-dispatch called an outbox row 'sent' the moment
-- Resend's POST /emails returned 2xx. That is "accepted for sending", not
-- "delivered" -- Resend accepts, queues, and may still bounce minutes later.
-- Nothing in MUSTER ever learned the difference, and a hard-bounced address
-- stayed in recipient_emails forever, costing mail.muster.partners reputation
-- on every subsequent alert.
--
-- Three parts:
--   1. muster.email_events   append-only provider event log, keyed by the
--                            Svix message id so a webhook replay is a no-op.
--   2. muster.email_suppressions  addresses that bounced or complained.
--   3. notification_outbox gains provider_message_id + delivery_status, which
--      is deliberately SEPARATE from status. status is the outbox's own work
--      state (pending/sending/sent/failed/skipped); delivery_status is what
--      the provider later reported about the message. 'sent' now means
--      accepted; only a webhook can make it 'delivered'.
--
-- Resend webhooks are account-wide, not domain-scoped: this Resend account
-- also carries BRD, GFFH and the 28FS domains. muster_engine_record_email_event
-- therefore matches on provider_message_id against MUSTER's own outbox and
-- returns matched=false for anything else, writing nothing. Another brand's
-- delivery data never lands in muster.*.

create table if not exists muster.email_events (
  id                  bigserial primary key,
  outbox_id           bigint not null references muster.notification_outbox(id) on delete cascade,
  provider_message_id text not null,
  event_type          varchar(32) not null
    check (event_type in ('sent','delivered','delivery_delayed','bounced','complained','failed','opened','clicked')),
  -- The Svix message id, prefixed. Unique, so a redelivered webhook inserts
  -- nothing and the handler answers 200 without touching state again.
  idempotency_key     text not null unique,
  occurred_at         timestamptz not null,
  detail              jsonb not null default '{}'::jsonb,
  created_at          timestamptz not null default now()
);

create index if not exists email_events_outbox on muster.email_events (outbox_id, occurred_at desc);
create index if not exists email_events_provider on muster.email_events (provider_message_id);

comment on table muster.email_events is
  'Append-only Resend event log for MUSTER application email. One row per provider event; idempotency_key is the Svix message id so replays are dropped.';

create table if not exists muster.email_suppressions (
  id          bigserial primary key,
  email       text not null,
  reason      varchar(16) not null check (reason in ('bounce','complaint')),
  source      varchar(32) not null default 'resend_webhook',
  detail      jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now()
);

-- Case-insensitive uniqueness. Addresses are stored lowercased by the RPC;
-- the functional index is belt and braces against a direct insert.
create unique index if not exists email_suppressions_email_key on muster.email_suppressions (lower(email));

comment on table muster.email_suppressions is
  'Addresses that hard-bounced or filed a spam complaint. muster_engine_claim_alerts drops them from recipient lists before dispatch.';

alter table muster.notification_outbox
  add column if not exists provider_message_id text,
  add column if not exists delivery_status     varchar(24),
  add column if not exists delivered_at        timestamptz,
  add column if not exists last_event_at       timestamptz;

create index if not exists notification_outbox_provider_message
  on muster.notification_outbox (provider_message_id)
  where provider_message_id is not null;

comment on column muster.notification_outbox.delivery_status is
  'What the provider reported: accepted, delivered, bounced, complained, failed. Separate from status, which is this table''s own work state. A 2xx from the send API only ever yields accepted.';

-- RLS: these two tables are service-role only. No tenant reads them directly;
-- delivery detail is operator data, and email_suppressions spans organizations.
alter table muster.email_events      enable row level security;
alter table muster.email_suppressions enable row level security;

-- Delivery-status ranking. Provider events arrive out of order often enough
-- that this matters: a late email.sent must never overwrite a delivered, and a
-- bounce must never be overwritten by anything.
create or replace function muster.delivery_status_rank(p_status text)
returns integer
language sql
immutable
set search_path to ''
as $$
  select case p_status
    when 'accepted'         then 1
    when 'delivery_delayed' then 2
    when 'delivered'        then 3
    when 'failed'           then 10
    when 'bounced'          then 11
    when 'complained'       then 12
    else 0
  end;
$$;

-- Records one provider event against MUSTER's outbox.
--
-- Returns jsonb rather than raising, because the caller is a webhook handler
-- that must answer 200 to almost everything: an event for another brand's mail,
-- or a redelivery, is a normal outcome and not an error. Only a genuine fault
-- should surface as an exception and let Resend retry.
create or replace function public.muster_engine_record_email_event(
  p_idempotency_key    text,
  p_provider_message_id text,
  p_event_type         text,
  p_occurred_at        timestamptz,
  p_recipients         text[] default '{}',
  p_detail             jsonb  default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_outbox      muster.notification_outbox%rowtype;
  v_new_status  text;
  v_suppressed  integer := 0;
  v_addr        text;
begin
  if p_idempotency_key is null or p_provider_message_id is null or p_event_type is null then
    raise exception 'idempotency key, provider message id and event type are all required'
      using errcode = '22023';
  end if;

  select * into v_outbox
  from muster.notification_outbox
  where provider_message_id = p_provider_message_id;

  -- Not ours. This Resend account is shared across 28FS brands and its
  -- webhooks are account-wide, so most events reaching the handler belong to
  -- someone else. Write nothing; the handler answers 200 and moves on.
  if not found then
    return jsonb_build_object('matched', false, 'duplicate', false);
  end if;

  begin
    insert into muster.email_events (outbox_id, provider_message_id, event_type, idempotency_key, occurred_at, detail)
    values (v_outbox.id, p_provider_message_id, p_event_type, p_idempotency_key, p_occurred_at, coalesce(p_detail, '{}'::jsonb));
  exception when unique_violation then
    -- Redelivery of an event already recorded. Idempotent by construction.
    return jsonb_build_object('matched', true, 'duplicate', true, 'outbox_id', v_outbox.id);
  end;

  -- Map the event onto a delivery status. opened/clicked deliberately do not:
  -- both fire for link scanners and image proxies, so neither is evidence a
  -- human did anything, and MUSTER does not report them as if they were.
  v_new_status := case p_event_type
    when 'sent'             then 'accepted'
    when 'delivered'        then 'delivered'
    when 'delivery_delayed' then 'delivery_delayed'
    when 'bounced'          then 'bounced'
    when 'complained'       then 'complained'
    when 'failed'           then 'failed'
    else null
  end;

  update muster.notification_outbox
  set last_event_at  = greatest(coalesce(last_event_at, p_occurred_at), p_occurred_at),
      delivery_status = case
        when v_new_status is null then delivery_status
        when muster.delivery_status_rank(v_new_status) > muster.delivery_status_rank(coalesce(delivery_status, ''))
          then v_new_status
        else delivery_status
      end,
      delivered_at = case
        when p_event_type = 'delivered' then coalesce(delivered_at, p_occurred_at)
        else delivered_at
      end
  where id = v_outbox.id;

  -- A hard bounce or a spam complaint retires the address for every future
  -- MUSTER send. Resend's own suppression list protects the account; this one
  -- keeps MUSTER from queueing the row in the first place, which is what keeps
  -- the alert visible as 'skipped' rather than silently dropped downstream.
  if p_event_type in ('bounced', 'complained') then
    foreach v_addr in array coalesce(p_recipients, '{}')
    loop
      if v_addr is null or btrim(v_addr) = '' then
        continue;
      end if;
      insert into muster.email_suppressions (email, reason, source, detail)
      values (
        lower(btrim(v_addr)),
        case when p_event_type = 'bounced' then 'bounce' else 'complaint' end,
        'resend_webhook',
        coalesce(p_detail, '{}'::jsonb)
      )
      on conflict (lower(email)) do nothing;
      v_suppressed := v_suppressed + 1;
    end loop;
  end if;

  return jsonb_build_object(
    'matched', true,
    'duplicate', false,
    'outbox_id', v_outbox.id,
    'delivery_status', v_new_status,
    'suppressed', v_suppressed
  );
end;
$$;

-- Claim, now suppression-aware.
--
-- Was `language sql`. It has to loop now, because a row whose every recipient
-- has bounced must not be handed to the dispatcher at all: sending it would
-- earn another bounce on a domain MUSTER shares with every other 28FS brand.
-- Such a row terminates as 'skipped' with the reason recorded, which is
-- visible, rather than being dropped somewhere downstream, which is not.
--
-- Suppressed addresses are filtered out of the RETURNED row only; the stored
-- recipient_emails is left intact so the register still shows who the alert
-- was originally addressed to, and so lifting a suppression restores delivery
-- with no backfill.
create or replace function public.muster_engine_claim_alerts(p_limit integer default 20)
returns setof muster.notification_outbox
language plpgsql
security definer
set search_path to ''
as $$
declare
  r      muster.notification_outbox%rowtype;
  v_live text[];
begin
  for r in
    update muster.notification_outbox
    set status = 'sending'
    where id in (
      select id from muster.notification_outbox
      where status = 'pending'
      order by created_at
      limit p_limit
      for update skip locked
    )
    returning *
  loop
    select coalesce(array_agg(a), '{}')
      into v_live
    from unnest(r.recipient_emails) a
    where not exists (
      select 1 from muster.email_suppressions s
      where s.email = lower(btrim(a))
    );

    if coalesce(array_length(v_live, 1), 0) = 0 then
      update muster.notification_outbox
      set status = 'skipped',
          last_error = 'every recipient is suppressed (bounce or complaint)'
      where id = r.id;
      continue;
    end if;

    r.recipient_emails := v_live;
    return next r;
  end loop;
end;
$$;

-- Resolve, now able to record what the provider called the message.
--
-- p_provider_message_id is the id Resend returns from POST /emails. Without it
-- stored, an inbound webhook has nothing to join on and delivery tracking is
-- impossible. Defaulted, so the previous three-argument call still resolves.
--
-- 'sent' here means accepted for sending. delivery_status is set to 'accepted'
-- to say exactly that; only muster_engine_record_email_event can raise it to
-- 'delivered'.
create or replace function public.muster_engine_resolve_alert(
  p_id                  bigint,
  p_status              text,
  p_error               text default null,
  p_provider_message_id text default null
)
returns void
language plpgsql
security definer
set search_path to ''
as $$
begin
  if p_status not in ('sent','failed') then
    raise exception 'p_status must be sent or failed' using errcode = '22023';
  end if;

  if p_status = 'sent' then
    update muster.notification_outbox
    set status = 'sent',
        attempts = attempts + 1,
        last_error = null,
        sent_at = now(),
        provider_message_id = coalesce(p_provider_message_id, provider_message_id),
        delivery_status = coalesce(delivery_status, 'accepted')
    where id = p_id;
  else
    -- transient failure: requeue to pending for the next dispatch cycle
    -- unless this was already the 5th attempt, in which case dead-letter.
    update muster.notification_outbox
    set attempts = attempts + 1,
        last_error = p_error,
        status = case when attempts + 1 >= 5 then 'failed' else 'pending' end
    where id = p_id;
  end if;
end;
$$;

-- The three-argument resolve_alert is now shadowed by the four-argument form
-- above (the fourth defaults), so a three-argument call would be ambiguous.
-- Drop the old entry.
drop function if exists public.muster_engine_resolve_alert(bigint, text, text);

-- Grants. Postgres grants EXECUTE to PUBLIC on every new function, so a fresh
-- definition starts more permissive than its neighbours until this runs. Match
-- the existing muster_engine_* ACL exactly: postgres and service_role, nobody
-- else. anon and authenticated must never reach these -- they write delivery
-- state and the suppression list.
revoke all on function public.muster_engine_record_email_event(text, text, text, timestamptz, text[], jsonb) from public;
revoke all on function public.muster_engine_claim_alerts(integer) from public;
revoke all on function public.muster_engine_resolve_alert(bigint, text, text, text) from public;
revoke all on function muster.delivery_status_rank(text) from public;

grant execute on function public.muster_engine_record_email_event(text, text, text, timestamptz, text[], jsonb) to service_role;
grant execute on function public.muster_engine_claim_alerts(integer) to service_role;
grant execute on function public.muster_engine_resolve_alert(bigint, text, text, text) to service_role;