-- The switch for AI support triage. Ships dark: the kill switch is on and the default is off, so a
-- request is read by nobody but support until an owner turns it on in the console's Feature Flags
-- (kill switch off, default on). enforcement is set by 20261003043005, the migration that adds the
-- code reading it.

insert into cavscope.feature_flags (key, name, description, scope, default_enabled, kill_switch, category, surface, plan_minimum)
values ('support_ai', 'AI support triage', 'When on, each in-app support request (message, page details and the screenshot if attached) is read by an AI model, which writes a summary, a likely cause, a suggested fix and a DRAFT reply that is emailed to support for a person to review. Nothing is sent to the customer by the AI.', 'platform', false, true, 'workspace', 'cavscope-support-request edge function / public.cavscope_engine_support_ai_enabled', null)
on conflict (key) do nothing;
