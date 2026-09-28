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
      'email', new.email,
      'site_url', new.site_url,
      'marketing_consent', new.marketing_consent,
      'created_at', new.created_at,
      'offer_deadline', '2026-09-26T15:59:00Z'
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
      'email', new.email,
      'site_url', new.site_url
    )
  );

  return new;
end;
$$;
