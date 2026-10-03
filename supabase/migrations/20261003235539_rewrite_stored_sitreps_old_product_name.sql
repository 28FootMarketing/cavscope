-- Stored SITREPs still said "Prepared by MUSTER", "MUSTER is not a law firm" and "MUSTER marketing site".
-- The owner confirmed on 2026-10-03 that the old reports are test runs and do not matter, and asked for
-- the old name to go everywhere. 127 reports carried it in content_md, 18 in the headline and 216 in
-- the sections JSON.
--
-- content_sha256 is the sha256 (hex) of content_md -- all 239 matched before this ran -- so it is
-- recomputed for every rewritten row, and the block raises, rolling everything back, if any report still
-- carries the old name afterwards or any hash disagrees with its content. Lowercase URLs and identifiers
-- (muster.partners in scanned evidence) are untouched: replace() here is case-sensitive.

do $$
declare bad int;
begin
  update cavscope.sitreps set
    content_md = replace(replace(content_md, 'MUSTER', 'CavScope'), 'Muster', 'CavScope'),
    headline = replace(replace(headline, 'MUSTER', 'CavScope'), 'Muster', 'CavScope'),
    sections = replace(replace(sections::text, 'MUSTER', 'CavScope'), 'Muster', 'CavScope')::jsonb
  where content_md ~ '(MUSTER|Muster)' or headline ~ '(MUSTER|Muster)' or sections::text ~ '(MUSTER|Muster)';

  update cavscope.sitreps set content_sha256 = encode(sha256(convert_to(content_md, 'UTF8')), 'hex')
  where content_sha256 is distinct from encode(sha256(convert_to(content_md, 'UTF8')), 'hex');

  select count(*) into bad from cavscope.sitreps
   where content_md ~ '(MUSTER|Muster)' or headline ~ '(MUSTER|Muster)' or sections::text ~ '(MUSTER|Muster)'
      or content_sha256 is distinct from encode(sha256(convert_to(content_md, 'UTF8')), 'hex');
  if bad <> 0 then raise exception 'sitreps still wrong after rewrite: %', bad; end if;
end $$;
