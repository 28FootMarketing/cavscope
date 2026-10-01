-- Rename plan stage 3, half B (database): point the 4 cron jobs and the 3 functions that
-- call an edge function by URL at the cavscope-* slugs deployed by stage 3 half A.
-- Only the URL path changes. Cron JOB names stay (cavscope.* readers key on them); the
-- x-muster-secret header and Vault secret names stay (later stages). Each rewrite asserts
-- that exactly the expected old URLs were present, and that none remain afterwards.
do $$
declare
  r record; def text; newdef text; n int := 0;
  base constant text := 'https://hjowfnzpomzxazmzywxw.supabase.co/functions/v1/';
begin
  for r in select jobid, command from cron.job
           where command like '%' || base || 'muster-%' loop
    perform cron.alter_job(r.jobid, command := replace(r.command, base || 'muster-', base || 'cavscope-'));
    n := n + 1;
  end loop;
  if n <> 4 then raise exception 'expected 4 cron jobs, rewrote %', n; end if;

  n := 0;
  for r in select p.oid from pg_proc p
           where p.oid in ('cavscope.do_request_scan(bigint,bigint,bigint,text)'::regprocedure,
                           'public.cavscope_create_api_key(bigint,text,text,text[],timestamp with time zone)'::regprocedure,
                           'public.muster_notify_beta_signup()'::regprocedure) loop
    def := pg_get_functiondef(r.oid);
    newdef := replace(def, base || 'muster-', base || 'cavscope-');
    if newdef = def then raise exception 'no url found in %', r.oid::regprocedure; end if;
    execute newdef;
    n := n + 1;
  end loop;
  if n <> 3 then raise exception 'expected 3 functions, rewrote %', n; end if;

  if exists (select 1 from cron.job where command like '%' || base || 'muster-%')
     or exists (select 1 from pg_proc p join pg_namespace s on s.oid = p.pronamespace
                where s.nspname in ('public','cavscope') and p.prokind = 'f'
                  and pg_get_functiondef(p.oid) like '%' || base || 'muster-%') then
    raise exception 'an old edge-function url remains';
  end if;
end $$;
