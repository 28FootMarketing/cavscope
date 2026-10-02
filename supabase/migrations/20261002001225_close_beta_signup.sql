-- Close the public beta signup. Owner's instruction 2026-10-02.
-- The page is closed in middleware.js, but the real control is here: anon and
-- authenticated could insert straight through PostgREST. Existing rows are untouched.
-- To reopen: alter policy public_insert_only on public.muster_beta_signups with check (true);
do $$
begin
  alter policy public_insert_only on public.muster_beta_signups with check (false);
  if (select pg_get_expr(polwithcheck, polrelid) from pg_policy
      where polrelid = 'public.muster_beta_signups'::regclass and polname = 'public_insert_only') <> 'false' then
    raise exception 'policy was not closed';
  end if;
  if (select count(*) from public.muster_beta_signups) <> 2 then
    raise exception 'unexpected row count';
  end if;
end $$;
