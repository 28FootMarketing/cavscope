-- Domain Monitor shows the TLS certificate (engine http-native-1.16.0 writes a tls_certificate evidence row
-- on every scan; tls-cert.ts).
--
-- Three states, and they are not the same thing:
--   not_observed  the site's latest scan wrote no certificate row (it ran on an older engine, or never ran)
--   unavailable   the engine tried and the runtime or the server did not allow the read; 'reason' says why
--                 (connect_failed, requires_tls13, no_socket_api, ...). This is the proof, or the disproof,
--                 that the deployed edge runtime allows the socket the check needs.
--   ok            it read the certificate: expiry, issuer, number of names, TLS version
-- Days remaining are counted from now(), not copied from the evidence, so the figure does not go stale
-- between scans; it is still "as of the last scan" and the page says so.
--
-- try_jsonb exists because evidence excerpts are text and one malformed row must blank one cell, not the
-- whole console payload. Closed to anon and authenticated; only the SECURITY DEFINER caller reaches it.
-- The function edit is in place with each step asserted to match exactly once.

create or replace function cavscope.try_jsonb(p text)
 returns jsonb
 language plpgsql
 immutable
 set search_path to ''
as $f$
begin
  return p::jsonb;
exception when others then
  return null;
end;
$f$;
revoke all on function cavscope.try_jsonb(text) from public, anon, authenticated;

do $mig$
declare
  v_def text := pg_get_functiondef('public.cavscope_admin_domain_monitor()'::regprocedure);
  n int;
  steps text[][] := array[
    array[$a$where e.kind in ('dns_mx', 'dns_txt', 'dns_caa', 'dns_ds', 'header_set')$a$,
          $b$where e.kind in ('dns_mx', 'dns_txt', 'dns_caa', 'dns_ds', 'header_set', 'tls_certificate')$b$],
    array[$a$(select count(*) from ev e where e.website_id = w.id and e.kind = 'header_set' and e.http_status is not null) as header_rows,$a$,
          $b$(select e.excerpt from ev e where e.website_id = w.id and e.kind = 'tls_certificate' limit 1) as cert,
          (select count(*) from ev e where e.website_id = w.id and e.kind = 'header_set' and e.http_status is not null) as header_rows,$b$],
    array[$a$'changes_30d', coalesce(cs.n, 0),$a$,
          $b$'certificate', case when c.cert is null then jsonb_build_object('state', 'not_observed')
                              else (select case
                                      when z.j is null then jsonb_build_object('state', 'unreadable')
                                      when z.j ->> 'state' = 'ok' then jsonb_build_object('state', 'ok',
                                           'host', z.j ->> 'host',
                                           'not_after', z.j #>> '{cert,not_after}',
                                           'days_remaining', floor(extract(epoch from ((z.j #>> '{cert,not_after}')::timestamptz - now())) / 86400)::int,
                                           'issuer', coalesce(z.j #>> '{cert,issuer_org}', z.j #>> '{cert,issuer_cn}'),
                                           'names', jsonb_array_length(coalesce(z.j #> '{cert,san}', '[]'::jsonb)),
                                           'self_signed', coalesce((z.j #>> '{cert,self_signed}')::boolean, false),
                                           'tls_version', z.j ->> 'tls_version')
                                      else jsonb_build_object('state', 'unavailable', 'reason', z.j ->> 'reason')
                                    end
                                    from (select cavscope.try_jsonb(c.cert) as j) z) end,
        'changes_30d', coalesce(cs.n, 0),$b$]
  ];
  i int;
begin
  for i in 1 .. array_length(steps, 1) loop
    n := (length(v_def) - length(replace(v_def, steps[i][1], ''))) / greatest(length(steps[i][1]), 1);
    if n <> 1 then raise exception 'step %: expected exactly 1 match, found %', i, n; end if;
    v_def := replace(v_def, steps[i][1], steps[i][2]);
  end loop;
  execute v_def;
end
$mig$;
