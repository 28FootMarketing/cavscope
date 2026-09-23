-- MUSTER 083: GOV-006, GOV-007, GOV-008 -- the AIO view's missing pillars.
--
-- WHY
--
-- app.html's "AIO & Generative Engine Optimization (GEO) Audit" view sells five
-- pillars: crawlability and rendering, entity clarity, structured data, LLM
-- surface (/llms.txt) and citability. The engine checked two of them. It never
-- requested /llms.txt, never read a JSON-LD block, and its client-rendered
-- detector only ever downgraded confidence on other rules; it never reported
-- the rendering itself. Meanwhile the view's "Run AIO Audit" button printed a
-- scripted terminal -- "llms.txt -> HTTP 404", "Schema.org Organization found",
-- "empty <div id=root> shell" -- for every domain anyone typed, and scored the
-- pillars with the site's overall security posture. A confident claim about
-- bytes the engine never read, which is the one thing this product must not do.
--
-- WHAT THE ENGINE DOES (http-native-1.8.0, supabase/functions/muster-scan/aio.ts)
--
-- GOV-006: GET /llms.txt at the scanned origin. A 200 is not enough -- a
--   single-page app answers every path with its HTML shell -- so the file must
--   not be HTML and must open with a Markdown H1, which the llms.txt format
--   requires.
-- GOV-007: every application/ld+json block on the served homepage is parsed.
--   Fires when none parses. An unparseable block is counted and not credited,
--   because every consumer discards it too.
-- GOV-008: the homepage is client-rendered (html.ts detectClientRendered), so
--   crawlers that do not run JavaScript -- which includes the main AI crawlers --
--   receive the shell.
--
-- SEVERITY
--
-- GOV-006 and GOV-007 info: neither is a defect a visitor meets, llms.txt is a
-- proposal rather than a standard, and no AI provider has published that it
-- ranks by either. Info weighs 0 in posture, so neither moves a score.
-- GOV-008 low, matching GOV-001/002: content no crawler can read is a real
-- visibility loss, and it is the one of the three that also affects search.
--
-- FRAMEWORK
--
-- CUSTOM "AIO readiness", like GOV-003..005. No framework cites these; mapping
-- them to one would be a citation invented to look complete.
--
-- INACTIVE ON PURPOSE
--
-- A rule waits for the engine that emits it (muster_063: ingest drops findings
-- whose rule is inactive and counts them as skipped_inactive). Floor, not
-- equality: http-native-1.8.0. Proof of deploy is the evidence rows keyed
-- llms_txt (http_probe) and jsonld (html_excerpt), written on every reachable
-- HTML scan whatever the verdict, since a well-prepared site keeps all three
-- rules silent. This file must be applied BEFORE that engine deploys:
-- findings.rule_id is a foreign key, and an unknown rule fails the ingest.

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
