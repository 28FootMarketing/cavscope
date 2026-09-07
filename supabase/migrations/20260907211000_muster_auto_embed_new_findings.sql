-- Auto-embed new findings and evidence for retrieval search.
-- When a finding is created, schedule an embedding job.
-- When evidence is captured, schedule an embedding job.
--
-- Note: This uses pg_cron to defer embedding (avoids blocking the scan engine).
-- The actual embedding happens in a separate edge function (muster-backfill-embeddings)
-- called via pg_net or a scheduled job, or manually via curl.
--
-- For MVP: Manual backfill via edge function is simpler and sufficient.
-- add `select cron.schedule('muster-auto-embed', '*/5 * * * *', 'select ...')` when ready.

-- Mark findings/evidence that need embedding
create table if not exists muster.embedding_queue (
  id bigserial primary key,
  entity_type text not null check (entity_type in ('finding', 'evidence')),
  entity_id bigint not null,
  created_at timestamptz not null default now(),
  processed_at timestamptz,
  unique(entity_type, entity_id)
);

create index if not exists idx_embedding_queue_unprocessed on muster.embedding_queue(created_at)
  where processed_at is null;

-- Trigger: queue finding for embedding when created
create or replace function muster.queue_finding_for_embedding()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  insert into muster.embedding_queue (entity_type, entity_id)
  values ('finding', new.id)
  on conflict do nothing;
  return new;
end;
$$;

create trigger trg_queue_finding_for_embedding
after insert on muster.findings
for each row
execute function muster.queue_finding_for_embedding();

-- Trigger: queue evidence for embedding when created
create or replace function muster.queue_evidence_for_embedding()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  insert into muster.embedding_queue (entity_type, entity_id)
  values ('evidence', new.id)
  on conflict do nothing;
  return new;
end;
$$;

create trigger trg_queue_evidence_for_embedding
after insert on muster.evidences
for each row
execute function muster.queue_evidence_for_embedding();

-- Cron job: Call backfill endpoint every 5 minutes (commented out for MVP)
-- Uncomment after embedding infrastructure is proven reliable in staging.
-- select cron.schedule('muster-auto-embed', '*/5 * * * *',
--   'select pg_net.http_post(
--     url := current_setting(''muster.backfill_endpoint''),
--     body := jsonb_build_object(
--       ''type'', ''all'',
--       ''batch_size'', 10
--     )::text,
--     headers := jsonb_build_object(
--       ''authorization'', ''Bearer '' || current_setting(''muster.service_key''),
--       ''content-type'', ''application/json''
--     )
--   )');
