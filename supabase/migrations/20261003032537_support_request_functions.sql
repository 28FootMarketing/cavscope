-- Two functions over cavscope.support_requests.
--
-- cavscope_submit_support_request: the signed-in caller files a request. Category is a
-- fixed list (a pick-list, not free text), the message is 1 to 4000 characters, an
-- organization may be named only if the caller has a role in it, and a person is held to
-- 10 requests an hour so the form cannot be used to flood the support inbox.
-- authenticated only; anon revoked by name.
--
-- cavscope_engine_finish_support_request: the edge function records whether the email
-- reached the support inbox. service_role only; revoked from anon and authenticated by
-- name, as every engine function must be.

create or replace function public.cavscope_submit_support_request(
  p_category text, p_message text, p_page_url text default null, p_user_agent text default null,
  p_viewport text default null, p_organization_id bigint default null, p_has_screenshot boolean default false)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid bigint := cavscope.current_user_id();
  v_id bigint;
begin
  if v_uid is null then raise exception 'sign in required' using errcode = '42501'; end if;
  if p_category is null or p_category not in ('broken','wrong_number','how_to','billing','other') then
    raise exception 'unknown category' using errcode = '22023';
  end if;
  if p_message is null or char_length(btrim(p_message)) not between 1 and 4000 then
    raise exception 'message must be 1 to 4000 characters' using errcode = '22023';
  end if;
  if p_organization_id is not null and cavscope.org_role(p_organization_id) is null then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if (select count(*) from cavscope.support_requests r where r.user_id = v_uid and r.created_at > now() - interval '1 hour') >= 10 then
    raise exception 'too many support messages this hour; please wait and try again' using errcode = '54000';
  end if;
  insert into cavscope.support_requests (user_id, organization_id, category, message, page_url, user_agent, viewport, has_screenshot)
  values (v_uid, p_organization_id, p_category, btrim(p_message), left(p_page_url, 500), left(p_user_agent, 400), left(p_viewport, 40), coalesce(p_has_screenshot, false))
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function public.cavscope_submit_support_request(text, text, text, text, text, bigint, boolean) from public, anon;
grant execute on function public.cavscope_submit_support_request(text, text, text, text, text, bigint, boolean) to authenticated;

create or replace function public.cavscope_engine_finish_support_request(p_id bigint, p_ok boolean, p_email text default null, p_error text default null)
returns void
language sql
security definer
set search_path = ''
as $$
  update cavscope.support_requests
     set status = case when p_ok then 'forwarded' else 'failed' end,
         email = coalesce(left(p_email, 320), email),
         forward_error = case when p_ok then null else left(p_error, 400) end,
         forwarded_at = case when p_ok then now() else null end
   where id = p_id;
$$;
revoke all on function public.cavscope_engine_finish_support_request(bigint, boolean, text, text) from public, anon, authenticated;
grant execute on function public.cavscope_engine_finish_support_request(bigint, boolean, text, text) to service_role;
