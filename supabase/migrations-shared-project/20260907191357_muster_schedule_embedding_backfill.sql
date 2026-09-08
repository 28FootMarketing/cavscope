-- Retrieval was degrading silently. Nothing ever drained new work.
--
-- The auto-embed triggers queue every new finding and evidence row into
-- muster.embedding_queue, and muster-backfill-embeddings knows how to embed
-- them, but no cron job ever invoked it. The only runs it has ever had were
-- manual. So every scan after the initial backfill added evidence that
-- search_findings and search_evidence could never return.
--
-- Caught by muster.test_retrieval_contract() -- embeddings_complete went from
-- 11/11 to 10/11 within hours of the suite being written, after a scan at
-- 2026-09-07 18:15 left 8 evidence rows unembedded and 16 queue rows unread.
--
-- Scheduled every 15 minutes using the house pattern: cron_safe_post with the
-- x-muster-secret shared secret from vault, matching muster-watchdog-10min.
-- The call is a cheap no-op when nothing is pending (the function returns
-- "Backfill complete" with 0 embedded), so the steady-state cost is one HTTP
-- request per cycle, and embedding spend only happens when there is new work.

select cron.schedule(
  'muster-embedding-backfill-15min',
  '*/15 * * * *',
  $cron$
  select public.cron_safe_post(
    'muster-embedding-backfill-15min',
    'https://mgtmqucaldkaxvxglguw.supabase.co/functions/v1/muster-backfill-embeddings',
    jsonb_build_object(
      'Content-Type', 'application/json',
      'x-muster-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'muster_cron_secret' limit 1)),
    jsonb_build_object('batch_size', 25, 'type', 'all'),
    55000);
  $cron$
);
