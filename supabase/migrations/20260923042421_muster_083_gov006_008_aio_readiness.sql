insert into muster.scan_rules (
  rule_id, category, title, description, default_severity, check_type,
  framework_refs, remediation, plain_english, active
) values
(
  'GOV-006', 'governance',
  'No llms.txt file',
  'GET /llms.txt at the site root did not return an llms.txt file: a plain-text Markdown file opening with an H1 that names the site, then a short summary and links to the pages that matter. An HTML page answering that path (a catch-all route) does not count. llms.txt is a proposed convention, not a standard; no AI provider has published that it ranks or cites by it.',
  'info', 'http_native',
  '{"CUSTOM":"AIO readiness"}'::jsonb,
  'Publish /llms.txt as text/plain or text/markdown: "# Site name", a one-line "> summary", then "## " sections listing the key pages as Markdown links with one-line descriptions. Keep it to pages that are public and current, and update it when they change.',
  'Your site has no short summary file written for AI assistants. Adding one gives them a clean list of your most important pages. It is optional and cheap, and it does not guarantee they will use it.'
  , false
),
(
  'GOV-007', 'governance',
  'No readable structured data (JSON-LD)',
  'The served homepage has no application/ld+json block that parses as JSON, so nothing states in machine-readable form which organization, product or service the site represents. Blocks that fail to parse are counted and not credited, because every consumer discards them too. Structured data injected by script after load is not seen by crawlers that do not run JavaScript.',
  'info', 'http_native',
  '{"CUSTOM":"AIO readiness"}'::jsonb,
  'Add a <script type="application/ld+json"> block to the homepage describing the organization (schema.org Organization or the closest subtype: name, url, logo, sameAs, contact point), in the served HTML rather than injected by script. Validate it with the Schema.org validator before deploying.',
  'Your homepage does not describe your organization in the standard format search engines and AI assistants read, so they have to guess who you are from the page text.'
  , false
),
(
  'GOV-008', 'governance',
  'Homepage content is rendered by script, not served',
  'The served homepage carries almost no readable text and loads script, so its content is built in the browser. Crawlers that do not execute JavaScript, which includes the main AI crawlers, receive the empty shell rather than the page a visitor sees. Detected by a text-length heuristic on the served HTML, not by rendering the page, so it is reported at medium confidence.',
  'low', 'http_native',
  '{"CUSTOM":"AIO readiness"}'::jsonb,
  'Serve the homepage''s content in the initial HTML: server-side rendering or static pre-rendering in the site''s framework, or a pre-rendering service for crawlers. Confirm by fetching the page with JavaScript disabled, or with curl, and checking the main text is present.',
  'Your homepage builds its content in the visitor''s browser. AI assistants and some search tools read the page without running that code, so to them your homepage looks almost empty.'
  , false
)
on conflict (rule_id) do nothing;

do $$
declare
  v_n int;
  v_inactive int;
  v_total int;
begin
  select count(*) into v_n from muster.scan_rules
   where (rule_id, default_severity) in (('GOV-006','info'), ('GOV-007','info'), ('GOV-008','low'))
     and not active and category = 'governance' and check_type = 'http_native'
     and framework_refs = '{"CUSTOM":"AIO readiness"}'::jsonb;
  if v_n <> 3 then
    raise exception 'expected 3 inactive GOV-006..008 rules with the stated severities, found %', v_n;
  end if;

  select count(*), count(*) filter (where not active) into v_total, v_inactive from muster.scan_rules;
  if v_inactive <> 3 then
    raise exception 'expected exactly 3 inactive rules (GOV-006..008), found %', v_inactive;
  end if;
  raise notice 'GOV-006..008 added inactive; % rules total', v_total;
end $$;