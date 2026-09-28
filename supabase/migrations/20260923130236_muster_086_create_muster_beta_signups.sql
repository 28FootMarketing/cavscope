create table if not exists public.muster_beta_signups (
  id uuid primary key default gen_random_uuid(),
  full_name text not null,
  company_name text not null,
  email text not null,
  site_url text not null,
  marketing_consent boolean not null default false,
  status text not null default 'new',
  created_at timestamptz not null default now(),
  constraint muster_beta_signups_email_check check (email ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'),
  constraint muster_beta_signups_site_url_check check (site_url ~* '^https?://')
);

alter table public.muster_beta_signups enable row level security;

drop policy if exists "public_insert_only" on public.muster_beta_signups;
create policy "public_insert_only"
  on public.muster_beta_signups
  for insert
  to anon, authenticated
  with check (true);
