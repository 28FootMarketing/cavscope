-- Extends the MUSTER beta offer deadline from 2026-09-26 15:59:00+00
-- (9/26/2026 11:59 AM ET) to 2026-09-29 03:59:00+00 (9/28/2026 11:59 PM ET,
-- EDT/UTC-4 -- DST does not end until 2026-11-01, so ET is still EDT on this
-- date). Two places hardcode the deadline: the insert-time guard trigger,
-- and the Telegram notify payload's display string. beta.html's own error
-- handling only pattern-matches "offer closed" in the guard's raised
-- message, so it needs no code change, but the guard's message text is
-- updated too so a raised error stays accurate if anything ever surfaces it
-- directly.

create or replace function public.muster_beta_signup_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if now() > timestamptz '2026-09-29 03:59:00+00' then
    raise exception 'MUSTER beta offer closed 9/28/2026 11:59 PM ET' using errcode = '23514';
  end if;
  return new;
end;
$$;

create or replace function public.muster_notify_beta_signup()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_secret text;
begin
  select decrypted_secret into v_secret
  from vault.decrypted_secrets
  where name = 'muster_beta_notify_secret';

  perform net.http_post(
    url := 'https://hjowfnzpomzxazmzywxw.supabase.co/functions/v1/muster-beta-notify',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-muster-signal', v_secret
    ),
    body := jsonb_build_object(
      'full_name', new.full_name,
      'company_name', new.company_name,
      'industry', new.industry,
      'email', new.email,
      'site_url', new.site_url,
      'marketing_consent', new.marketing_consent,
      'created_at', new.created_at,
      'offer_deadline', '2026-09-29T03:59:00Z'
    )
  );

  perform net.http_post(
    url := 'https://hjowfnzpomzxazmzywxw.supabase.co/functions/v1/muster-beta-confirm',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-muster-signal', v_secret
    ),
    body := jsonb_build_object(
      'full_name', new.full_name,
      'company_name', new.company_name,
      'industry', new.industry,
      'email', new.email,
      'site_url', new.site_url
    )
  );

  return new;
end;
$$;

do $$
declare
  v_guard_def text;
  v_notify_def text;
begin
  select pg_get_functiondef(oid) into v_guard_def from pg_proc
   where proname = 'muster_beta_signup_guard' and pronamespace = 'public'::regnamespace;
  if v_guard_def not like '%2026-09-29 03:59:00%' then
    raise exception 'muster_beta_signup_guard does not carry the new deadline';
  end if;
  if v_guard_def like '%2026-09-26%' then
    raise exception 'muster_beta_signup_guard still references the old deadline';
  end if;

  select pg_get_functiondef(oid) into v_notify_def from pg_proc
   where proname = 'muster_notify_beta_signup' and pronamespace = 'public'::regnamespace;
  if v_notify_def not like '%2026-09-29T03:59:00Z%' then
    raise exception 'muster_notify_beta_signup does not carry the new deadline';
  end if;
  if v_notify_def like '%2026-09-26%' then
    raise exception 'muster_notify_beta_signup still references the old deadline';
  end if;
end $$;
