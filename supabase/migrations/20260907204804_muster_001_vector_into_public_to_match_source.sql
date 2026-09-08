-- On the source project (mgtmqucaldkaxvxglguw) pgvector lives in `public`, and
-- every muster migration is written against `public.vector` -- function
-- signatures, cast targets, the ivfflat opclass references. A blank Supabase
-- project installs it into `extensions` instead.
--
-- Moving it to match the source is the cheap fix. The alternative is rewriting
-- `public.vector` in 46 migration files, which would also mean the repo no
-- longer reproduces the project it was written for.
alter extension vector set schema public;
