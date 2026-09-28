alter table public.muster_beta_signups
  add column if not exists industry text not null default '';

-- drop the default now that the column exists cleanly on an empty table,
-- so future inserts are forced to supply it
alter table public.muster_beta_signups alter column industry drop default;
