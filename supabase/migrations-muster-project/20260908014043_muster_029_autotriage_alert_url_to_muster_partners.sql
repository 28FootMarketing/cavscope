-- muster.autotriage() builds the plain-text half of a critical/high risk alert
-- and hardcodes where to go read the detail. It still said
-- https://app.muster.28footsystems.com/ -- a host that resolves, but is no
-- longer the product's home, and lands on the workspace root rather than /app.
--
-- The HTML half of the same email already points at MUSTER_APP_URL (default
-- https://app.muster.partners/app) from muster-alert-dispatch. So a recipient
-- opening the HTML part and a recipient on a text-only client were being sent
-- to two different places. Now they agree.
--
-- Applied identically on mgtmqucaldkaxvxglguw so the two projects stay
-- checksum-identical on the function layer.
--
-- The body is read back out of the catalog and rewritten by substring
-- replacement rather than restated. Retyping a 5 KB plpgsql body to change one
-- URL is how muster_016 and muster_017 happened.
--
-- NOTE: this URL is now a literal in two places -- here, and MUSTER_APP_URL's
-- default in muster-alert-dispatch. They must be changed together.
do $$
declare d text;
begin
  select pg_get_functiondef(p.oid) into d
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'muster' and p.proname = 'autotriage';

  if position('https://app.muster.28footsystems.com/' in d) = 0 then
    raise notice 'autotriage already points at the current host; nothing to do';
    return;
  end if;

  execute replace(d, 'https://app.muster.28footsystems.com/', 'https://app.muster.partners/app');
end $$;
