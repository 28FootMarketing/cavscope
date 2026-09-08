-- Drops the anon-reachable, token-gated write endpoint created in muster_023.
-- The 653 rows it existed to carry have landed (708 total on this project,
-- including the 77 embedding-queue rows the insert triggers generated), so it
-- has no remaining purpose and no longer gets to exist.
--
-- Anything that needs to write to muster.* from here on goes through the
-- public.muster_* RPCs like everything else, under RLS and real auth.
drop function if exists public.muster_bulk_import(text, text, jsonb);
