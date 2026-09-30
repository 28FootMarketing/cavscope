-- One list of industries, read by every form that asks for one.
--
-- Until now "industry" was free text on three forms (app.html's organization
-- setup, onboarding.html, beta.html), so the same answer arrived written
-- different ways: the two beta signups on file say "Consulting" and "Business
-- Operations Consulting". A dropdown fed from this table keeps one spelling per
-- industry. The column that stores the answer (organizations.industry,
-- muster_beta_signups.industry) stays text and stores the label, so no existing
-- row changes and no caller breaks; a value typed before this list existed is
-- still shown and kept, never silently replaced.

create table if not exists cavscope.industries (
  key        varchar(40) primary key check (key ~ '^[a-z0-9_]+$'),
  label      varchar(80) not null unique,
  sort_order integer not null,
  created_at timestamptz not null default now()
);
alter table cavscope.industries enable row level security;
revoke all on cavscope.industries from public, anon, authenticated;

insert into cavscope.industries (key, label, sort_order) values
  ('accounting',      'Accounting & Tax',                       10),
  ('agriculture',     'Agriculture',                            20),
  ('construction',    'Construction & Trades',                  30),
  ('consulting',      'Consulting & Professional Services',     40),
  ('education_k12',   'Education (K-12)',                       50),
  ('education_higher','Education (Higher Education)',           60),
  ('energy',          'Energy & Utilities',                     70),
  ('financial',       'Financial Services & Fintech',           80),
  ('government',      'Government & Public Sector',             90),
  ('healthcare',      'Healthcare & Life Sciences',            100),
  ('hospitality',     'Hospitality & Food Service',            110),
  ('insurance',       'Insurance',                             120),
  ('legal',           'Legal Services',                        130),
  ('manufacturing',   'Manufacturing',                         140),
  ('marketing',       'Marketing & Advertising',               150),
  ('media',           'Media & Entertainment',                 160),
  ('nonprofit',       'Nonprofit & Community Organizations',   170),
  ('real_estate',     'Real Estate',                           180),
  ('retail',          'Retail & E-commerce',                   190),
  ('technology',      'Software & Technology',                 200),
  ('sports',          'Sports & Athletics',                    210),
  ('transportation',  'Transportation & Logistics',            220),
  ('other',           'Other',                                 999)
on conflict (key) do update set label = excluded.label, sort_order = excluded.sort_order;

-- Public reference data, like published pricing: the beta form is signed out,
-- so anon reads it too. Named cavscope_*, not muster_*: no new name carries
-- the retired brand (CLAUDE.md).
create or replace function public.cavscope_industries()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object('key', key, 'label', label) order by sort_order), '[]'::jsonb)
  from cavscope.industries;
$$;
revoke all on function public.cavscope_industries() from public;
grant execute on function public.cavscope_industries() to anon, authenticated;

do $$
begin
  if jsonb_array_length(public.cavscope_industries()) <> 23 then
    raise exception 'industry catalog did not load 23 rows';
  end if;
  if (public.cavscope_industries() -> -1 ->> 'key') <> 'other' then
    raise exception 'Other must sort last';
  end if;
end $$;
