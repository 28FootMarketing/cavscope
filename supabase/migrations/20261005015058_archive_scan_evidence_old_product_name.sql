-- Owner-directed 2026-10-05: archive captured evidence that quotes the old product name. Copies are kept
-- exactly as captured (nothing reworded) in a table nobody but the service role can read; the originals
-- are removed from the live evidence library by a separate delete.
create table if not exists cavscope.scan_evidence_archive (
  like cavscope.scan_evidence including defaults,
  archived_at timestamptz not null default now(),
  archive_reason text not null
);
alter table cavscope.scan_evidence_archive enable row level security;   -- no policies: service role only
revoke all on cavscope.scan_evidence_archive from anon, authenticated, public;

insert into cavscope.scan_evidence_archive
select e.*, now(), 'captured source of our own pages quoting the retired product name'
  from cavscope.scan_evidence e
 where (e.url || coalesce(e.excerpt, '')) ~* 'muster'
   and not exists (select 1 from cavscope.scan_evidence_archive a where a.id = e.id);
