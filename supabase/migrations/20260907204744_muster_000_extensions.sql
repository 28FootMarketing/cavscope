-- MUSTER moves to its own project (was mgtmqucaldkaxvxglguw, the shared 28FS hub).
-- Extensions the muster stack needs, in the schema layout Supabase expects.
create extension if not exists vector    with schema extensions;
create extension if not exists pg_net    with schema extensions;
create extension if not exists pg_cron;
create extension if not exists pgcrypto  with schema extensions;
