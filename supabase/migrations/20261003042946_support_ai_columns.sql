-- AI triage of support requests: where the model's notes are kept.
--
-- The screenshot is never stored. ai_screen_notes is the model's written description of the interface
-- state (which page, which panel, an error message), told not to copy personal data from the screen.
-- Everything here is written only by cavscope_engine_finish_support_ai (service_role), and nothing is
-- sent to the customer: the draft reply goes to the support inbox for a person to review.

alter table cavscope.support_requests
  add column if not exists ai_status text check (ai_status in ('pending','done','failed','skipped')),
  add column if not exists ai_kind text check (ai_kind in ('how_to','probable_bug','data_question','billing_or_account','unclear')),
  add column if not exists ai_confidence text check (ai_confidence in ('low','medium','high')),
  add column if not exists ai_summary text check (char_length(ai_summary) <= 600),
  add column if not exists ai_screen_notes text check (char_length(ai_screen_notes) <= 1200),
  add column if not exists ai_likely_cause text check (char_length(ai_likely_cause) <= 1200),
  add column if not exists ai_suggested_fix text check (char_length(ai_suggested_fix) <= 1600),
  add column if not exists ai_draft_reply text check (char_length(ai_draft_reply) <= 2400),
  add column if not exists ai_model text check (char_length(ai_model) <= 100),
  add column if not exists ai_error text check (char_length(ai_error) <= 300),
  add column if not exists ai_at timestamptz;
