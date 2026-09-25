create or replace function public.muster_beta_signup_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if now() > timestamptz '2026-09-26 15:59:00+00' then
    raise exception 'MUSTER beta offer closed 9/26/2026 11:59 AM ET' using errcode = '23514';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_muster_beta_signup_guard on public.muster_beta_signups;
create trigger trg_muster_beta_signup_guard
  before insert on public.muster_beta_signups
  for each row execute function public.muster_beta_signup_guard();
