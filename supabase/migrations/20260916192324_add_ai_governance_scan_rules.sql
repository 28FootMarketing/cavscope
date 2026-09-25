insert into muster.scan_rules
  (rule_id, category, title, description, default_severity, check_type, framework_refs, remediation, plain_english)
values
('ai-chatbot-present-undisclosed', 'ai_governance', 'Conversational AI present without disclosure',
 'Site serves a chatbot/conversational AI widget but no scanned page or policy text discloses that the visitor is interacting with an AI system.',
 'medium', 'browser', '{"colorado_chatbot_act":"HB 26-1263"}',
 'Add a clear, conspicuous disclosure at first interaction that the chat is AI-driven, per emerging chatbot safety statutes (e.g. Colorado HB 26-1263).',
 'Your site has a chat assistant. Visitors need to be told up front it''s AI, not a person.'),

('ai-admt-policy-silent', 'ai_governance', 'Automated decision-making used without policy disclosure',
 'Site shows behavioral evidence of automated decisioning (scoring, eligibility screening, personalized pricing/ranking) but privacy policy text contains no automated-decision-making disclosure.',
 'high', 'http_native', '{"colorado_admt_act":"SB 26-189"}',
 'Add an ADMT disclosure section to the privacy policy: what''s automated, what data feeds it, and how to request human review, per Colorado ADMT Act (SB 26-189) and similar state frameworks.',
 'Your site appears to make automated decisions about visitors. Your policy needs to say so and explain their rights.'),

('ai-vendor-undisclosed', 'ai_governance', 'Third-party AI vendor undisclosed',
 'Detected script/API calls to a known third-party AI service (chat, recommendation, generative content) with no corresponding vendor disclosure in the privacy policy.',
 'medium', 'browser', '{}',
 'List the AI vendor and its role in data processing in the privacy policy or a subprocessor list.',
 'You''re using an outside AI tool on your site. Your policy should name it and say what it does with visitor data.'),

('ai-generated-content-undisclosed', 'ai_governance', 'AI-generated content shown without disclosure',
 'Page content shows strong indicators of AI generation (e.g. explicit CMS/API markers, not stylistic guessing) with no disclosure label, relevant under state AI-content-transparency laws (e.g. CA SB 942).',
 'low', 'manual', '{"california_ai_transparency_act":"SB 942"}',
 'Label AI-generated content per applicable transparency requirements.',
 'Some content on your site looks machine-generated. Some states require you to say so.'),

('ai-crawler-directives-missing', 'ai_governance', 'No AI-crawler policy in robots.txt / llms.txt',
 'Site has no explicit directives for AI crawlers (GPTBot, Google-Extended, CCBot, anthropic-ai, etc.) and no llms.txt, leaving AI-training/indexing posture undefined.',
 'info', 'http_native', '{}',
 'Add explicit AI-crawler rules to robots.txt and consider publishing an llms.txt to state your content-use position.',
 'You haven''t told AI crawlers what they can or can''t do with your content. Worth deciding on purpose, not by default.');
