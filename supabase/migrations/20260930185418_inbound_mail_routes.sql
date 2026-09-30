-- support@ and security@ forward to a real inbox.
--
-- Mail to CavScope's published addresses arrives through Resend inbound on
-- mail.cavscope.28footsystems.com (and the retired mail.muster.partners, so
-- links already in the wild still land). Until this migration nothing read it:
-- no Resend webhook pointed at this project, so a vulnerability report sent to
-- security@ sat in Resend's received list and nobody was told. The
-- cavscope-inbound-mail edge function now forwards each message to the
-- addresses in this table, reply-to the original sender, so answering from the
-- owner's inbox answers the person who wrote in. Same design as ARS's admin@
-- relay (raqciluiznwztltqejka, ars-inbound-email).
--
-- Routes are data, not code: where an address forwards is changed with an
-- update here, no deploy. The forward-to addresses are inserted outside this
-- file so no personal inbox is committed to the repository.

create table if not exists cavscope.mail_routes (
  address     text primary key
              check (address = lower(address) and address ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  forward_to  text[] not null check (cardinality(forward_to) between 1 and 5),
  sender      text not null,          -- the From on the forward
  subject_tag text not null,          -- prefixed to the forwarded subject
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- One row per (message, address) forwarded. Resend redelivers a webhook it did
-- not see a 2xx for, so without this a slow send would be forwarded twice.
create table if not exists cavscope.mail_forwards (
  email_id   text not null,
  address    text not null,
  status     text not null check (status in ('claimed', 'sent', 'failed')),
  error      text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (email_id, address)
);

alter table cavscope.mail_routes enable row level security;
alter table cavscope.mail_forwards enable row level security;
revoke all on cavscope.mail_routes, cavscope.mail_forwards from public, anon, authenticated;

-- The webhook signing secret lives in Vault under this name. Read only here,
-- only by the service role.
create or replace function public.cavscope_engine_inbound_secret()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select decrypted_secret from vault.decrypted_secrets
  where name = 'cavscope_resend_inbound_webhook_secret'
  order by created_at desc limit 1;
$$;

-- Routes for the addresses a message was sent to. Anything else is another
-- brand's mail on the shared Resend account and gets no row back.
create or replace function public.cavscope_engine_mail_routes(p_addresses text[])
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'address', r.address, 'forward_to', to_jsonb(r.forward_to),
           'sender', r.sender, 'subject_tag', r.subject_tag) order by r.address), '[]'::jsonb)
  from cavscope.mail_routes r
  where r.address = any (select lower(trim(a)) from unnest(coalesce(p_addresses, '{}'::text[])) a);
$$;

-- Claim a (message, address) before sending. True means send; false means it
-- was already sent, or another delivery is sending it right now. A failed one,
-- or a claim abandoned for ten minutes, can be claimed again.
create or replace function public.cavscope_engine_claim_mail_forward(p_email_id text, p_address text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare v_ok boolean;
begin
  insert into cavscope.mail_forwards (email_id, address, status)
  values (p_email_id, lower(p_address), 'claimed')
  on conflict (email_id, address) do update
    set status = 'claimed', error = null, updated_at = now()
    where cavscope.mail_forwards.status = 'failed'
       or (cavscope.mail_forwards.status = 'claimed' and cavscope.mail_forwards.updated_at < now() - interval '10 minutes')
  returning true into v_ok;
  return coalesce(v_ok, false);
end;
$$;

create or replace function public.cavscope_engine_finish_mail_forward(p_email_id text, p_address text, p_ok boolean, p_error text default null)
returns void
language sql
security definer
set search_path = ''
as $$
  update cavscope.mail_forwards
     set status = case when p_ok then 'sent' else 'failed' end,
         error = case when p_ok then null else left(p_error, 500) end,
         updated_at = now()
   where email_id = p_email_id and address = lower(p_address);
$$;

-- Supabase grants every new public function to anon and authenticated by
-- default, and revoking from PUBLIC does not undo that (CLAUDE.md). Named.
revoke all on function public.cavscope_engine_inbound_secret() from public, anon, authenticated;
revoke all on function public.cavscope_engine_mail_routes(text[]) from public, anon, authenticated;
revoke all on function public.cavscope_engine_claim_mail_forward(text, text) from public, anon, authenticated;
revoke all on function public.cavscope_engine_finish_mail_forward(text, text, boolean, text) from public, anon, authenticated;
grant execute on function public.cavscope_engine_inbound_secret() to service_role;
grant execute on function public.cavscope_engine_mail_routes(text[]) to service_role;
grant execute on function public.cavscope_engine_claim_mail_forward(text, text) to service_role;
grant execute on function public.cavscope_engine_finish_mail_forward(text, text, boolean, text) to service_role;

do $$
declare f text;
begin
  foreach f in array array[
    'public.cavscope_engine_inbound_secret()',
    'public.cavscope_engine_mail_routes(text[])',
    'public.cavscope_engine_claim_mail_forward(text,text)',
    'public.cavscope_engine_finish_mail_forward(text,text,boolean,text)'] loop
    if has_function_privilege('anon', f, 'execute') or has_function_privilege('authenticated', f, 'execute') then
      raise exception '% is callable from a browser', f;
    end if;
  end loop;
end $$;
