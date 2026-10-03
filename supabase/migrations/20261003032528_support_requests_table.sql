-- In-app support requests. Written only through public.cavscope_submit_support_request
-- (next migration); nothing reads this table from a browser. The screenshot a person
-- attaches is emailed to support and never stored: it can show anything on their
-- screen, so keeping it would be keeping more than the ticket needs. has_screenshot
-- records only whether one was sent.

create table if not exists cavscope.support_requests (
  id              bigint generated always as identity primary key,
  user_id         bigint,
  organization_id bigint,
  email           text,
  category        text not null check (category in ('broken','wrong_number','how_to','billing','other')),
  message         text not null check (char_length(btrim(message)) between 1 and 4000),
  page_url        text check (char_length(page_url) <= 500),
  user_agent      text check (char_length(user_agent) <= 400),
  viewport        text check (char_length(viewport) <= 40),
  has_screenshot  boolean not null default false,
  status          text not null default 'new' check (status in ('new','forwarded','failed')),
  forward_error   text check (char_length(forward_error) <= 400),
  created_at      timestamptz not null default now(),
  forwarded_at    timestamptz
);
create index if not exists support_requests_user_created_idx on cavscope.support_requests (user_id, created_at desc);
alter table cavscope.support_requests enable row level security;
revoke all on cavscope.support_requests from public, anon, authenticated;
comment on table cavscope.support_requests is 'In-app support messages. Written only through public.cavscope_submit_support_request; the screenshot is never stored, only emailed (has_screenshot says whether one was sent).';
