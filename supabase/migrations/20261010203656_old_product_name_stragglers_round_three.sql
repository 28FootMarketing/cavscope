-- Cross-section check (2026-10-10): old-name stragglers found by searching every text column in the
-- cavscope schema.
--
-- Three stored SITREPs (245, 246, 248) were generated before the source text was corrected and carry
-- "MUSTER treats WCAG 2.2 AA ..." in sections.jurisdiction, which the SITREP viewer prints to the tenant.
-- content_md and content_sha256 are unaffected (the hash is over the markdown, which was already clean).
update cavscope.sitreps
   set sections = replace(sections::text, 'MUSTER treats', 'CavScope treats')::jsonb
 where id in (245, 246, 248)
   and sections::text like '%MUSTER treats%';

-- Descriptions that name the code behind a notification category or a flag still named the retired
-- schema and functions. They are read by the owner in the console, but the target is zero.
-- (support_ai's note keeps MUSTER_OPENROUTER_API_KEY: that is the real name of the secret.)
update cavscope.notification_categories
   set description = regexp_replace(regexp_replace(description, 'muster([_-])', 'cavscope\1', 'g'), 'muster\.', 'cavscope.', 'g')
 where description ~* 'muster';

update cavscope.feature_flags
   set surface     = regexp_replace(regexp_replace(surface,     'muster([_-])', 'cavscope\1', 'g'), 'muster\.', 'cavscope.', 'g'),
       description = regexp_replace(regexp_replace(description, 'muster([_-])', 'cavscope\1', 'g'), 'muster\.', 'cavscope.', 'g'),
       wiring_note = regexp_replace(regexp_replace(wiring_note, 'muster([_-])', 'cavscope\1', 'g'), 'muster\.', 'cavscope.', 'g')
 where coalesce(surface, '') || coalesce(description, '') || coalesce(wiring_note, '') ~* 'muster';
