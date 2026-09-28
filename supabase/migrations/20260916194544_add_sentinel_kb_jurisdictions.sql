insert into muster.jurisdictions (code, kind, name, parent_code, country_code, advisory, reviewed_at)
values
  ('CN', 'country', 'China', null, 'CN', 'Sentinel KB merge — AI regulation tracking added 2026-09-16.', current_date),
  ('KR', 'country', 'South Korea', null, 'KR', 'Sentinel KB merge — AI regulation tracking added 2026-09-16.', current_date),
  ('VN', 'country', 'Vietnam', null, 'VN', 'Sentinel KB merge — AI regulation tracking added 2026-09-16.', current_date),
  ('COE', 'supranational', 'Council of Europe', null, null, 'Sentinel KB merge — AI regulation tracking added 2026-09-16.', current_date),
  ('US-FED', 'region', 'United States (federal)', 'US', 'US', 'Sentinel KB merge — represents federal-level AI-relevant law distinct from any single state.', current_date),
  ('US-MULTI', 'region', 'United States (multi-state pattern)', 'US', 'US', 'Sentinel KB merge — represents a rolling multi-state legislative pattern, not a single jurisdiction.', current_date)
on conflict (code) do nothing;
