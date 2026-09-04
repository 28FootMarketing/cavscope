-- MUSTER phase 1: self-serve onboarding, jurisdiction advisories, white-label brand profiles,
-- user personalization, plans + feature flags (super admin), and agent/API-key identities.
-- Project: mgtmqucaldkaxvxglguw, schema: muster

------------------------------------------------------------------------------
-- Organizations: plan, jurisdiction, onboarding state
------------------------------------------------------------------------------
alter table muster.organizations
  add column if not exists plan varchar(16) not null default 'trial',
  add column if not exists country_code char(2),
  add column if not exists region_code varchar(8),
  add column if not exists timezone varchar(64) not null default 'America/New_York',
  add column if not exists website_limit integer not null default 1,
  add column if not exists onboarding_status varchar(16) not null default 'started',
  add column if not exists onboarding_completed_at timestamptz,
  add column if not exists created_by_id bigint references muster.users(id);

alter table muster.organizations drop constraint if exists organizations_plan_check;
alter table muster.organizations add constraint organizations_plan_check
  check (plan in ('trial','starter','pro','enterprise','internal'));
alter table muster.organizations drop constraint if exists organizations_onboarding_check;
alter table muster.organizations add constraint organizations_onboarding_check
  check (onboarding_status in ('started','profile','website','first_scan','complete'));

-- Platform-level roles. 'super_admin' sees and controls every tenant.
alter table muster.users drop constraint if exists users_role_check;
alter table muster.users add constraint users_role_check check (role in ('user','admin','super_admin'));

alter table muster.activity_events add column if not exists agent_id bigint;

------------------------------------------------------------------------------
-- Plans
------------------------------------------------------------------------------
create table if not exists muster.plans (
  plan          varchar(16) primary key,
  rank          integer not null unique,
  name          varchar(64) not null,
  website_limit integer not null,
  scan_cadence_min_minutes integer not null,
  description   text not null
);
insert into muster.plans (plan, rank, name, website_limit, scan_cadence_min_minutes, description) values
('trial', 0, 'Trial', 1, 1440, '14-day evaluation. One website, daily scans, SITREPs with MUSTER attribution.'),
('starter', 1, 'Starter', 3, 720, 'Up to three websites, twice-daily scans, white-label branding.'),
('pro', 2, 'Pro', 15, 60, 'Up to fifteen websites, hourly scans, custom domain, attribution removal, agent API.'),
('enterprise', 3, 'Enterprise', 1000, 60, 'Unlimited websites, SSO-ready, dedicated agent keys, custom SLAs.'),
('internal', 9, 'Internal (28FS)', 1000, 60, '28 Foot Systems internal workspace. All features.')
on conflict (plan) do update set rank = excluded.rank, name = excluded.name, website_limit = excluded.website_limit,
  scan_cadence_min_minutes = excluded.scan_cadence_min_minutes, description = excluded.description;

------------------------------------------------------------------------------
-- Countries (ISO 3166-1 alpha-2) for the onboarding dropdown
------------------------------------------------------------------------------
create table if not exists muster.countries (
  code char(2) primary key,
  name varchar(96) not null,
  has_regions boolean not null default false
);
insert into muster.countries (code, name) values
('AF','Afghanistan'),('AL','Albania'),('DZ','Algeria'),('AD','Andorra'),('AO','Angola'),('AG','Antigua and Barbuda'),('AR','Argentina'),('AM','Armenia'),('AU','Australia'),('AT','Austria'),('AZ','Azerbaijan'),('BS','Bahamas'),('BH','Bahrain'),('BD','Bangladesh'),('BB','Barbados'),('BY','Belarus'),('BE','Belgium'),('BZ','Belize'),('BJ','Benin'),('BT','Bhutan'),('BO','Bolivia'),('BA','Bosnia and Herzegovina'),('BW','Botswana'),('BR','Brazil'),('BN','Brunei'),('BG','Bulgaria'),('BF','Burkina Faso'),('BI','Burundi'),('KH','Cambodia'),('CM','Cameroon'),('CA','Canada'),('CV','Cabo Verde'),('CF','Central African Republic'),('TD','Chad'),('CL','Chile'),('CN','China'),('CO','Colombia'),('KM','Comoros'),('CG','Congo'),('CD','Congo (DRC)'),('CR','Costa Rica'),('CI','Cote d''Ivoire'),('HR','Croatia'),('CU','Cuba'),('CY','Cyprus'),('CZ','Czechia'),('DK','Denmark'),('DJ','Djibouti'),('DM','Dominica'),('DO','Dominican Republic'),('EC','Ecuador'),('EG','Egypt'),('SV','El Salvador'),('GQ','Equatorial Guinea'),('ER','Eritrea'),('EE','Estonia'),('SZ','Eswatini'),('ET','Ethiopia'),('FJ','Fiji'),('FI','Finland'),('FR','France'),('GA','Gabon'),('GM','Gambia'),('GE','Georgia'),('DE','Germany'),('GH','Ghana'),('GR','Greece'),('GD','Grenada'),('GT','Guatemala'),('GN','Guinea'),('GW','Guinea-Bissau'),('GY','Guyana'),('HT','Haiti'),('HN','Honduras'),('HK','Hong Kong'),('HU','Hungary'),('IS','Iceland'),('IN','India'),('ID','Indonesia'),('IR','Iran'),('IQ','Iraq'),('IE','Ireland'),('IL','Israel'),('IT','Italy'),('JM','Jamaica'),('JP','Japan'),('JO','Jordan'),('KZ','Kazakhstan'),('KE','Kenya'),('KI','Kiribati'),('KW','Kuwait'),('KG','Kyrgyzstan'),('LA','Laos'),('LV','Latvia'),('LB','Lebanon'),('LS','Lesotho'),('LR','Liberia'),('LY','Libya'),('LI','Liechtenstein'),('LT','Lithuania'),('LU','Luxembourg'),('MO','Macao'),('MG','Madagascar'),('MW','Malawi'),('MY','Malaysia'),('MV','Maldives'),('ML','Mali'),('MT','Malta'),('MH','Marshall Islands'),('MR','Mauritania'),('MU','Mauritius'),('MX','Mexico'),('FM','Micronesia'),('MD','Moldova'),('MC','Monaco'),('MN','Mongolia'),('ME','Montenegro'),('MA','Morocco'),('MZ','Mozambique'),('MM','Myanmar'),('NA','Namibia'),('NR','Nauru'),('NP','Nepal'),('NL','Netherlands'),('NZ','New Zealand'),('NI','Nicaragua'),('NE','Niger'),('NG','Nigeria'),('KP','North Korea'),('MK','North Macedonia'),('NO','Norway'),('OM','Oman'),('PK','Pakistan'),('PW','Palau'),('PS','Palestine'),('PA','Panama'),('PG','Papua New Guinea'),('PY','Paraguay'),('PE','Peru'),('PH','Philippines'),('PL','Poland'),('PT','Portugal'),('PR','Puerto Rico'),('QA','Qatar'),('RO','Romania'),('RU','Russia'),('RW','Rwanda'),('KN','Saint Kitts and Nevis'),('LC','Saint Lucia'),('VC','Saint Vincent and the Grenadines'),('WS','Samoa'),('SM','San Marino'),('ST','Sao Tome and Principe'),('SA','Saudi Arabia'),('SN','Senegal'),('RS','Serbia'),('SC','Seychelles'),('SL','Sierra Leone'),('SG','Singapore'),('SK','Slovakia'),('SI','Slovenia'),('SB','Solomon Islands'),('SO','Somalia'),('ZA','South Africa'),('KR','South Korea'),('SS','South Sudan'),('ES','Spain'),('LK','Sri Lanka'),('SD','Sudan'),('SR','Suriname'),('SE','Sweden'),('CH','Switzerland'),('SY','Syria'),('TW','Taiwan'),('TJ','Tajikistan'),('TZ','Tanzania'),('TH','Thailand'),('TL','Timor-Leste'),('TG','Togo'),('TO','Tonga'),('TT','Trinidad and Tobago'),('TN','Tunisia'),('TR','Turkiye'),('TM','Turkmenistan'),('TV','Tuvalu'),('UG','Uganda'),('UA','Ukraine'),('AE','United Arab Emirates'),('GB','United Kingdom'),('US','United States'),('UY','Uruguay'),('UZ','Uzbekistan'),('VU','Vanuatu'),('VA','Vatican City'),('VE','Venezuela'),('VN','Vietnam'),('YE','Yemen'),('ZM','Zambia'),('ZW','Zimbabwe')
on conflict (code) do update set name = excluded.name;
update muster.countries set has_regions = true where code in ('US','CA','AU');

------------------------------------------------------------------------------
-- Jurisdictions and law advisories
-- Advisory text is informational. It is not legal advice. Each row carries
-- a review date so stale entries surface in the super admin console.
------------------------------------------------------------------------------
create table if not exists muster.jurisdictions (
  code          varchar(8) primary key,          -- 'US', 'US-CA', 'EU', 'CA-ON'
  kind          varchar(16) not null check (kind in ('supranational','country','region')),
  name          varchar(96) not null,
  parent_code   varchar(8) references muster.jurisdictions(code),
  country_code  char(2) references muster.countries(code),
  advisory      text not null,                    -- one-paragraph onboarding-level advisory
  reviewed_at   date not null,
  updated_at    timestamptz not null default now()
);

create table if not exists muster.jurisdiction_laws (
  id                bigint generated by default as identity primary key,
  jurisdiction_code varchar(8) not null references muster.jurisdictions(code) on delete cascade,
  short_name        varchar(64) not null,
  full_name         varchar(200) not null,
  category          varchar(24) not null check (category in ('privacy','accessibility','security','marketing','breach','consumer','sector')),
  applies_when      text not null,
  summary           text not null,
  obligations       jsonb not null default '[]'::jsonb,   -- ["Post a privacy policy", ...]
  rule_ids          text[] not null default '{}',          -- MUSTER scan rules that evidence compliance
  effective_date    date,
  reference_url     varchar(512),
  reviewed_at       date not null,
  unique (jurisdiction_code, short_name)
);
create index if not exists jurisdiction_laws_code_idx on muster.jurisdiction_laws (jurisdiction_code);

insert into muster.jurisdictions (code, kind, name, parent_code, country_code, advisory, reviewed_at) values
('GLOBAL','supranational','Global baseline',null,null,'Regardless of location, MUSTER treats WCAG 2.2 AA as the accessibility baseline, HTTPS everywhere as the security baseline, and a visible privacy policy as the privacy baseline. If you serve residents of the EU, UK, California, or Canada, their laws follow the visitor, not your office address.','2026-09-04'),
('EU','supranational','European Union',null,null,'GDPR applies to any site processing EU residents'' data, with consent required before non-essential cookies. The European Accessibility Act has applied to most e-commerce and digital services since 28 June 2025. NIS2 adds security duties for essential and important entities.','2026-09-04'),
('US','country','United States',null,'US','No single federal privacy law. ADA Title III is enforced against inaccessible commercial websites through litigation and DOJ settlements, with WCAG 2.1 AA as the de facto standard. CAN-SPAM, COPPA (under 13), the FTC Act, and TCPA apply nationally. Twenty states now have comprehensive privacy laws; pick your state to see which.','2026-09-04'),
('CA','country','Canada',null,'CA','PIPEDA governs commercial collection of personal information nationally, and CASL sets some of the strictest email and SMS consent rules in the world. Ontario (AODA) and Quebec (Law 25) add province-level accessibility and privacy obligations.','2026-09-04'),
('GB','country','United Kingdom',null,'GB','UK GDPR and the Data Protection Act 2018 mirror EU GDPR. PECR requires consent for non-essential cookies. The Equality Act 2010 requires reasonable adjustments, which courts read as accessible websites. Public sector bodies must meet WCAG 2.2 AA by regulation.','2026-09-04'),
('AU','country','Australia',null,'AU','The Privacy Act 1988 (Australian Privacy Principles) applies to most businesses over AUD 3M turnover and all health providers. The Disability Discrimination Act 1992 has been applied to websites since Maguire v SOCOG. The Spam Act 2003 requires consent and unsubscribe for commercial email.','2026-09-04'),
('NZ','country','New Zealand',null,'NZ','The Privacy Act 2020 applies to any agency collecting personal information, with mandatory breach notification. The Human Rights Act 1993 covers disability discrimination in goods and services, including websites. The Unsolicited Electronic Messages Act 2007 governs email marketing.','2026-09-04'),
('DE','country','Germany','EU','DE','GDPR plus the BDSG and TDDDG (cookie consent). The Barrierefreiheitsstaerkungsgesetz (BFSG) implements the European Accessibility Act for consumer-facing digital services from 28 June 2025. Impressum (legal notice) is mandatory on every commercial site.','2026-09-04'),
('FR','country','France','EU','FR','GDPR enforced by CNIL, which actively fines cookie-consent violations. Accessibility obligations under RGAA apply to public bodies and large companies, with the EAA extending them to consumer digital services from June 2025.','2026-09-04'),
('NL','country','Netherlands','EU','NL','GDPR enforced by the Autoriteit Persoonsgegevens. Cookie rules under the Telecommunicatiewet. Government sites must meet EN 301 549 (WCAG 2.1 AA); the EAA extends accessibility duties to consumer digital services.','2026-09-04'),
('IE','country','Ireland','EU','IE','GDPR enforced by the Data Protection Commission, lead regulator for many US tech companies. ePrivacy Regulations 2011 require cookie consent. The EAA is transposed through the European Union (Accessibility Requirements of Products and Services) Regulations 2023.','2026-09-04'),
('ES','country','Spain','EU','ES','GDPR plus the LOPDGDD. The AEPD publishes detailed cookie guidance and fines. Accessibility under Real Decreto 1112/2018 for public bodies and Ley 11/2023 implementing the EAA.','2026-09-04'),
('IT','country','Italy','EU','IT','GDPR enforced by the Garante, which has issued cookie-wall and consent decisions. Accessibility under the Stanca Act (Legge 4/2004) extended to large private companies, and the EAA via D.Lgs. 82/2022.','2026-09-04'),
('BR','country','Brazil',null,'BR','LGPD (Lei Geral de Protecao de Dados) applies to any processing of data of people in Brazil, with a legal basis required and a DPO recommended. The Brazilian Inclusion Law (13.146/2015) requires accessible websites for companies.','2026-09-04'),
('MX','country','Mexico',null,'MX','The Federal Law on Protection of Personal Data Held by Private Parties (LFPDPPP, revised 2025) requires a privacy notice (aviso de privacidad) at collection. Accessibility duties apply mainly to public bodies.','2026-09-04'),
('IN','country','India',null,'IN','The Digital Personal Data Protection Act 2023 requires notice and consent for personal data and applies to foreign sites serving Indian users. The Rights of Persons with Disabilities Act 2016 requires accessible ICT, with GIGW guidelines for government sites.','2026-09-04'),
('SG','country','Singapore',null,'SG','The PDPA requires consent, purpose limitation, and mandatory breach notification. The Spam Control Act covers commercial email. Accessibility is guided by the Digital Service Standards for government.','2026-09-04'),
('JP','country','Japan',null,'JP','The Act on the Protection of Personal Information (APPI) applies to businesses handling personal data of people in Japan, including overseas operators. JIS X 8341-3 (WCAG-aligned) is the accessibility standard, with the 2024 revision to the Disability Discrimination Act requiring reasonable accommodation from private businesses.','2026-09-04'),
('ZA','country','South Africa',null,'ZA','POPIA requires lawful processing, an Information Officer, and breach notification. The Electronic Communications and Transactions Act governs unsolicited email. Accessibility duties flow from the Promotion of Equality and Prevention of Unfair Discrimination Act.','2026-09-04'),
('AE','country','United Arab Emirates',null,'AE','Federal Decree-Law 45/2021 (PDPL) sets GDPR-style consent and breach duties, with separate regimes in DIFC and ADGM free zones. Accessibility follows the UAE Design System guidelines for government.','2026-09-04'),
('CH','country','Switzerland',null,'CH','The revised Federal Act on Data Protection (nFADP, September 2023) requires a privacy policy, breach notification, and a representative for foreign controllers. Accessibility duties apply to federal bodies (eCH-0059), with WCAG 2.1 AA as the standard.','2026-09-04'),
('NO','country','Norway',null,'NO','GDPR applies through the EEA. Norway requires WCAG 2.1 AA for all private-sector websites serving the public under the Universal Design regulation, one of the broadest accessibility mandates in the world.','2026-09-04'),
('SE','country','Sweden','EU','SE','GDPR enforced by IMY. The Swedish Web Accessibility Act (DOS-lagen) covers public bodies, with the EAA extending duties to consumer digital services from June 2025.','2026-09-04'),
('DK','country','Denmark','EU','DK','GDPR enforced by Datatilsynet, which has taken a strict view on Google Analytics transfers. Public sector accessibility under the Web Accessibility Act, extended by the EAA.','2026-09-04'),
('PL','country','Poland','EU','PL','GDPR enforced by UODO. The Act on Digital Accessibility of Websites covers public bodies; the EAA is implemented by the Act of 26 April 2024 for consumer services.','2026-09-04'),
('PT','country','Portugal','EU','PT','GDPR enforced by CNPD. Accessibility under Decreto-Lei 83/2018 for public bodies, extended by the EAA transposition (Decreto-Lei 82/2022).','2026-09-04'),
('BE','country','Belgium','EU','BE','GDPR enforced by the APD/GBA, which has ruled against IAB TCF consent strings. Accessibility for public bodies under regional decrees, extended by the EAA.','2026-09-04'),
('AT','country','Austria','EU','AT','GDPR enforced by the DSB, which issued the first Google Analytics transfer decision. Web-Zugaenglichkeits-Gesetz for public bodies; the Barrierefreiheitsgesetz implements the EAA from June 2025.','2026-09-04'),
('FI','country','Finland','EU','FI','GDPR enforced by the Data Protection Ombudsman. The Act on the Provision of Digital Services covers public bodies and, from June 2025, EAA-scoped private services.','2026-09-04')
on conflict (code) do update set name = excluded.name, parent_code = excluded.parent_code, advisory = excluded.advisory, reviewed_at = excluded.reviewed_at;

-- US states and DC
insert into muster.jurisdictions (code, kind, name, parent_code, country_code, advisory, reviewed_at)
select 'US-'||s.code, 'region', s.name, 'US', 'US',
  coalesce(s.advisory, 'No comprehensive state privacy law in force. Federal rules (ADA, CAN-SPAM, COPPA, FTC Act) and the state breach-notification statute still apply. Visitors from other states and countries bring their own laws with them.'),
  '2026-09-04'
from (values
('AL','Alabama',null),('AK','Alaska',null),('AZ','Arizona',null),('AR','Arkansas',null),
('CA','California','CCPA as amended by CPRA is the strictest US privacy law: privacy policy, "Do Not Sell or Share" link, opt-out preference signals (GPC), and data subject rights for businesses over USD 25M revenue or 100k consumers. CalOPPA requires a conspicuous privacy policy on every commercial site collecting Californian data. The Unruh Act makes ADA website claims a state cause of action with statutory damages.'),
('CO','Colorado','Colorado Privacy Act (effective 1 July 2023) requires opt-out of sale and targeted advertising, universal opt-out signal recognition, and data protection assessments for high-risk processing.'),
('CT','Connecticut','Connecticut Data Privacy Act (effective 1 July 2023) requires privacy notice, opt-out rights, universal opt-out signals from 2025, and consent for sensitive data.'),
('DE','Delaware','Delaware Personal Data Privacy Act (effective 1 January 2025) applies at 35k consumers with opt-out and consent-for-sensitive-data duties.'),
('FL','Florida','Florida Digital Bill of Rights (effective 1 July 2024) targets very large platforms (USD 1B revenue) but its minor-data and opt-out provisions reach more broadly. The Florida Information Protection Act governs breach notification.'),
('GA','Georgia',null),('HI','Hawaii',null),('ID','Idaho',null),('IL','Illinois','No comprehensive privacy law, but BIPA (Biometric Information Privacy Act) carries a private right of action with per-violation damages. Any face, voice, or fingerprint capture on the site needs written consent.'),
('IN','Indiana','Indiana Consumer Data Protection Act takes effect 1 January 2026 with opt-out rights and privacy notice duties for controllers over 100k consumers.'),
('IA','Iowa','Iowa Consumer Data Protection Act (effective 1 January 2025) is business-friendly but still requires a privacy notice and opt-out of sale.'),
('KS','Kansas',null),
('KY','Kentucky','Kentucky Consumer Data Protection Act takes effect 1 January 2026 with privacy notice, opt-out, and sensitive-data consent duties.'),
('LA','Louisiana',null),('ME','Maine',null),
('MD','Maryland','Maryland Online Data Privacy Act (effective 1 October 2025) is among the strictest: data minimization by default, a ban on selling sensitive data, and a low 35k-consumer threshold.'),
('MA','Massachusetts',null),('MI','Michigan',null),
('MN','Minnesota','Minnesota Consumer Data Privacy Act (effective 31 July 2025) requires privacy notice, opt-out, a documented data inventory, and a right to question profiling decisions.'),
('MS','Mississippi',null),('MO','Missouri',null),
('MT','Montana','Montana Consumer Data Privacy Act (effective 1 October 2024) applies at 50k consumers with opt-out and universal opt-out signal duties.'),
('NE','Nebraska','Nebraska Data Privacy Act (effective 1 January 2025) applies to any non-small business and requires privacy notice and opt-out.'),
('NV','Nevada','NRS 603A requires a privacy notice and a "Do Not Sell" request mechanism for operators collecting Nevadan data.'),
('NH','New Hampshire','New Hampshire Privacy Act (effective 1 January 2025) requires privacy notice, opt-out, and universal opt-out signals.'),
('NJ','New Jersey','New Jersey Data Privacy Act (effective 15 January 2025) applies at 100k consumers with universal opt-out signal recognition and data protection assessments.'),
('NM','New Mexico',null),('NY','New York','No comprehensive privacy law yet, but the SHIELD Act mandates reasonable security safeguards and breach notification for any business holding New Yorkers'' data. NYC Human Rights Law is used for website accessibility claims.'),
('NC','North Carolina',null),('ND','North Dakota',null),('OH','Ohio',null),('OK','Oklahoma',null),
('OR','Oregon','Oregon Consumer Privacy Act (effective 1 July 2024, nonprofits from 2025) requires privacy notice, a list of specific third parties on request, and universal opt-out signals from 2026.'),
('PA','Pennsylvania','No comprehensive privacy law in force (HB 78 pending). The Breach of Personal Information Notification Act, amended in 2023, sets 7-day AG notice and credit-monitoring duties. State agencies must meet WCAG 2.1 AA under Management Directive 205.42.'),
('RI','Rhode Island','Rhode Island Data Transparency and Privacy Protection Act takes effect 1 January 2026 and requires disclosure of every third party that receives personal data.'),
('SC','South Carolina',null),('SD','South Dakota',null),
('TN','Tennessee','Tennessee Information Protection Act (effective 1 July 2025) offers a safe harbor for businesses that adopt the NIST Privacy Framework.'),
('TX','Texas','Texas Data Privacy and Security Act (effective 1 July 2024) applies to any non-small business and requires privacy notice, opt-out, sensitive-data consent, and universal opt-out signals. The Texas AG actively enforces.'),
('UT','Utah','Utah Consumer Privacy Act (effective 31 December 2023) applies at USD 25M revenue with notice and opt-out duties.'),
('VT','Vermont',null),
('VA','Virginia','Virginia Consumer Data Protection Act (effective 1 January 2023) requires privacy notice, opt-out of sale and targeted ads, consent for sensitive data, and data protection assessments.'),
('WA','Washington','No comprehensive privacy law, but the My Health My Data Act (2024) covers any consumer health data with a private right of action, and the state breach statute is strict.'),
('WV','West Virginia',null),('WI','Wisconsin',null),('WY','Wyoming',null),('DC','District of Columbia',null)
) as s(code, name, advisory)
on conflict (code) do update set name = excluded.name, advisory = excluded.advisory, reviewed_at = excluded.reviewed_at;

-- Canadian provinces and territories
insert into muster.jurisdictions (code, kind, name, parent_code, country_code, advisory, reviewed_at)
select 'CA-'||s.code, 'region', s.name, 'CA', 'CA',
  coalesce(s.advisory, 'PIPEDA and CASL apply federally. No additional province-level private-sector privacy or accessibility statute changes your web obligations here.'),
  '2026-09-04'
from (values
('AB','Alberta','Alberta PIPA substitutes for PIPEDA for provincially regulated businesses and includes mandatory breach reporting.'),
('BC','British Columbia','BC PIPA substitutes for PIPEDA. The Accessible British Columbia Act sets accessibility standards, currently for public bodies.'),
('MB','Manitoba','The Accessibility for Manitobans Act includes an Information and Communications standard requiring accessible web content.'),
('NB','New Brunswick',null),('NL','Newfoundland and Labrador',null),('NS','Nova Scotia','The Accessibility Act (2017) is building standards toward 2030, including information and communication.'),
('NT','Northwest Territories',null),('NU','Nunavut',null),
('ON','Ontario','AODA requires WCAG 2.0 AA for all public websites of organizations with 50 or more employees, with accessibility compliance reports filed with the province.'),
('PE','Prince Edward Island',null),
('QC','Quebec','Law 25 (Bill 64) is Canada''s strictest privacy regime: privacy officer, privacy impact assessments, cookie consent, and fines up to CAD 25M or 4% of turnover. French-language requirements under the Charter of the French Language apply to sites serving Quebec.'),
('SK','Saskatchewan',null),('YT','Yukon',null)
) as s(code, name, advisory)
on conflict (code) do update set name = excluded.name, advisory = excluded.advisory, reviewed_at = excluded.reviewed_at;

-- Australian states and territories
insert into muster.jurisdictions (code, kind, name, parent_code, country_code, advisory, reviewed_at)
select 'AU-'||s.code, 'region', s.name, 'AU', 'AU',
  'Federal Privacy Act, DDA, and Spam Act apply. State privacy acts cover public agencies only.', '2026-09-04'
from (values ('NSW','New South Wales'),('VIC','Victoria'),('QLD','Queensland'),('WA','Western Australia'),('SA','South Australia'),('TAS','Tasmania'),('ACT','Australian Capital Territory'),('NT','Northern Territory')) as s(code, name)
on conflict (code) do update set name = excluded.name, advisory = excluded.advisory, reviewed_at = excluded.reviewed_at;

-- Law detail rows (in-app depth). rule_ids tie each law to scanner evidence.
insert into muster.jurisdiction_laws (jurisdiction_code, short_name, full_name, category, applies_when, summary, obligations, rule_ids, effective_date, reference_url, reviewed_at) values
('GLOBAL','WCAG 2.2 AA','Web Content Accessibility Guidelines 2.2, Level AA','accessibility','Always. Referenced by nearly every accessibility law worldwide.','The W3C standard for accessible web content. Level AA is the legal benchmark in the US, EU, UK, Canada, and Australia.','["Text alternatives for images","Keyboard operability","Sufficient color contrast","Declared page language","Descriptive titles and headings","Labelled form fields"]','{A11Y-001,A11Y-002,A11Y-003,A11Y-004,A11Y-005,A11Y-006,A11Y-007}','2023-10-05','https://www.w3.org/TR/WCAG22/','2026-09-04'),
('GLOBAL','HTTPS baseline','Transport security baseline','security','Always.','Serve every page over HTTPS with HSTS and modern security headers. Required by PCI DSS for card pages and expected by every privacy regulator as "appropriate technical measures".','["Redirect HTTP to HTTPS","Send HSTS","Set CSP, X-Frame-Options, nosniff, Referrer-Policy","Protect cookies with Secure, HttpOnly, SameSite"]','{SEC-001,SEC-002,SEC-003,SEC-004,SEC-005,SEC-006,SEC-007,SEC-008,SEC-010,SEC-011,SEC-013}',null,'https://owasp.org/www-project-secure-headers/','2026-09-04'),
('EU','GDPR','General Data Protection Regulation (EU) 2016/679','privacy','Processing personal data of people in the EU, regardless of where the business sits.','Lawful basis for every processing purpose, transparent privacy notice, data subject rights, 72-hour breach notification, and DPO or EU representative where required.','["Publish a compliant privacy notice (Art. 13)","Obtain consent before non-essential cookies (with ePrivacy)","Honor access, erasure, and portability requests","Notify the supervisory authority of breaches within 72 hours","Keep records of processing"]','{PRIV-001,PRIV-002,PRIV-003}','2018-05-25','https://eur-lex.europa.eu/eli/reg/2016/679/oj','2026-09-04'),
('EU','ePrivacy','ePrivacy Directive 2002/58/EC (cookie rules)','privacy','Any site storing or reading information on an EU visitor''s device.','Consent is required before non-essential cookies and trackers load. Analytics and advertising tags must wait for consent.','["Consent banner that blocks non-essential tags until accepted","Equal-prominence reject option","Record of consent"]','{PRIV-002}','2002-07-31','https://eur-lex.europa.eu/eli/dir/2002/58/oj','2026-09-04'),
('EU','EAA','European Accessibility Act, Directive (EU) 2019/882','accessibility','E-commerce, banking, transport, telecom, and e-books offered to EU consumers, from 28 June 2025. Microenterprises (under 10 staff and EUR 2M) are exempt for services.','Digital services must meet EN 301 549, which incorporates WCAG 2.1 AA. Enforcement is by national market surveillance authorities.','["Meet WCAG 2.1 AA","Publish an accessibility statement","Provide an accessible feedback channel"]','{A11Y-001,A11Y-002,A11Y-003,A11Y-004,A11Y-005,A11Y-006,A11Y-007}','2025-06-28','https://eur-lex.europa.eu/eli/dir/2019/882/oj','2026-09-04'),
('EU','NIS2','Directive (EU) 2022/2555 on network and information security','security','Essential and important entities in listed sectors (energy, health, digital infrastructure, digital providers, and more) with 50+ staff or EUR 10M turnover.','Risk-management measures, supply-chain security, incident reporting within 24 hours (early warning) and 72 hours, and management accountability.','["Adopt cyber risk management measures","Report significant incidents within 24/72 hours","Assess supplier security"]','{SEC-004,SEC-012,TP-001}','2024-10-17','https://eur-lex.europa.eu/eli/dir/2022/2555/oj','2026-09-04'),
('US','ADA Title III','Americans with Disabilities Act, Title III (public accommodations)','accessibility','Any business open to the public with a website. Enforced through private lawsuits and DOJ settlements.','Courts and DOJ treat WCAG 2.1 AA as the standard for accessible websites. Thousands of federal suits are filed each year, concentrated in NY, FL, and CA.','["Conform to WCAG 2.1 AA","Publish an accessibility statement with a contact path","Fix issues on a documented remediation timeline"]','{A11Y-001,A11Y-002,A11Y-003,A11Y-004,A11Y-005,A11Y-006,A11Y-007}','1992-01-26','https://www.ada.gov/resources/web-guidance/','2026-09-04'),
('US','ADA Title II rule','DOJ rule on web and mobile accessibility for state and local governments','accessibility','State and local government sites and apps, and vendors serving them. Compliance dates April 2026 (50k+ population) and April 2027 (smaller).','WCAG 2.1 AA is the mandatory technical standard.','["Conform to WCAG 2.1 AA by the compliance date","Cover third-party content the entity uses"]','{A11Y-001,A11Y-002,A11Y-003,A11Y-004,A11Y-005,A11Y-006,A11Y-007}','2024-06-24','https://www.ada.gov/resources/2024-03-08-web-rule/','2026-09-04'),
('US','CAN-SPAM','Controlling the Assault of Non-Solicited Pornography and Marketing Act','marketing','Any commercial email.','Accurate headers, physical address, clear opt-out honored within 10 business days.','["Include a physical mailing address in every commercial email","Honor unsubscribe within 10 business days","No deceptive subject lines"]','{}','2004-01-01','https://www.ftc.gov/business-guidance/resources/can-spam-act-compliance-guide-business','2026-09-04'),
('US','COPPA','Children''s Online Privacy Protection Act (2025 amendments)','privacy','Sites directed to children under 13, or with actual knowledge of collecting their data.','Verifiable parental consent before collecting personal data, a clear privacy notice, and data minimization. The 2025 rule tightened consent for targeted advertising and third-party disclosure.','["Verifiable parental consent","Child-directed privacy notice","Limit data retention"]','{PRIV-001,PRIV-002}','2000-04-21','https://www.ftc.gov/legal-library/browse/rules/childrens-online-privacy-protection-rule-coppa','2026-09-04'),
('US','FTC Act Section 5','Federal Trade Commission Act, Section 5 (unfair or deceptive practices)','consumer','Every US business.','Privacy policies must be truthful and followed. Inadequate security is treated as unfair. Dark patterns in consent flows are deceptive.','["Do what the privacy policy says","Maintain reasonable security","No dark patterns in consent or cancellation"]','{PRIV-001,SEC-001,SEC-013}','1914-09-26','https://www.ftc.gov/legal-library/browse/statutes/federal-trade-commission-act','2026-09-04'),
('US','TCPA','Telephone Consumer Protection Act','marketing','Any SMS or automated call to US numbers.','Prior express written consent for marketing texts and robocalls, with one-to-one consent per seller required since January 2025.','["Written consent per seller before marketing SMS","Honor STOP immediately","Keep consent records"]','{}','1991-12-20','https://www.fcc.gov/general/telemarketing-and-robocalls','2026-09-04'),
('US-CA','CCPA/CPRA','California Consumer Privacy Act as amended by the California Privacy Rights Act','privacy','For-profit businesses over USD 25M revenue, or buying/selling data of 100k+ consumers, or deriving 50%+ revenue from selling data, doing business in California.','Privacy policy with required disclosures, "Do Not Sell or Share My Personal Information" link, honoring Global Privacy Control, consumer rights (access, delete, correct, limit sensitive use), and annual risk assessments for high-risk processing.','["Privacy policy updated annually with CCPA disclosures","Do Not Sell or Share link in the footer","Honor Global Privacy Control signals","Respond to requests within 45 days","Contracts with service providers"]','{PRIV-001,PRIV-002}','2023-01-01','https://cppa.ca.gov/regulations/','2026-09-04'),
('US-CA','CalOPPA','California Online Privacy Protection Act','privacy','Any commercial website collecting personally identifiable information from Californians. No revenue threshold.','A conspicuously posted privacy policy that lists categories collected, third parties shared with, how Do Not Track is handled, and its effective date.','["Conspicuous privacy policy link","Disclose Do Not Track handling","Disclose third-party tracking"]','{PRIV-001,PRIV-002}','2004-07-01','https://leginfo.legislature.ca.gov/faces/codes_displaySection.xhtml?sectionNum=22575.&lawCode=BPC','2026-09-04'),
('US-CA','Unruh Act','Unruh Civil Rights Act (Civil Code 51)','accessibility','Any business establishment in California. ADA violations are automatically Unruh violations.','Statutory damages of USD 4,000 per violation plus attorney fees make California the most active venue for website accessibility suits.','["Conform to WCAG 2.1 AA","Respond to access barriers quickly"]','{A11Y-001,A11Y-002,A11Y-003,A11Y-004,A11Y-005,A11Y-006,A11Y-007}','1959-01-01','https://leginfo.legislature.ca.gov/faces/codes_displaySection.xhtml?sectionNum=51.&lawCode=CIV','2026-09-04'),
('US-IL','BIPA','Illinois Biometric Information Privacy Act','privacy','Any collection of biometric identifiers (face geometry, voiceprint, fingerprint) from Illinois residents.','Written informed consent, a public retention policy, and a private right of action with USD 1,000 to 5,000 per violation (per person since the 2024 amendment).','["Written consent before biometric capture","Published retention and destruction schedule","No sale of biometric data"]','{PRIV-001}','2008-10-03','https://www.ilga.gov/legislation/ilcs/ilcs3.asp?ActID=3004','2026-09-04'),
('US-NY','SHIELD Act','Stop Hacks and Improve Electronic Data Security Act','security','Any business holding private information of New York residents.','Reasonable administrative, technical, and physical safeguards, and breach notification to affected persons and the AG.','["Documented security program","Encrypt data in transit and at rest","Breach notification"]','{SEC-001,SEC-002,SEC-011,SEC-013}','2020-03-21','https://ag.ny.gov/resources/organizations/data-breach-reporting/shield-act','2026-09-04'),
('US-PA','BPINA','Breach of Personal Information Notification Act (as amended 2023)','breach','Any entity holding personal information of Pennsylvania residents.','Notify affected residents without unreasonable delay; state agencies notify within 7 days; credit monitoring required when SSNs or bank data are exposed.','["Incident response plan","Notify residents and, above 500, consumer reporting agencies","Offer credit monitoring where required"]','{SEC-011,SEC-012}','2006-06-20','https://www.legis.state.pa.us/cfdocs/legis/LI/uconsCheck.cfm?txtType=HTM&yr=2005&sessInd=0&smthLwInd=0&act=0094.','2026-09-04'),
('US-TX','TDPSA','Texas Data Privacy and Security Act','privacy','Any business (except SBA-defined small businesses) processing Texans'' data. Small businesses still need consent to sell sensitive data.','Privacy notice, opt-out of sale, targeted advertising and profiling, consent for sensitive data, universal opt-out signal recognition, and data protection assessments.','["Privacy notice with TDPSA disclosures","Opt-out mechanism and GPC support","Consent before processing sensitive data"]','{PRIV-001,PRIV-002}','2024-07-01','https://www.texasattorneygeneral.gov/consumer-protection/file-consumer-complaint/consumer-privacy-rights','2026-09-04'),
('US-VA','VCDPA','Virginia Consumer Data Protection Act','privacy','Controllers processing data of 100k+ Virginians, or 25k+ with 50% revenue from data sales.','Privacy notice, opt-out rights, sensitive data consent, and data protection assessments.','["Privacy notice","Opt-out of sale and targeted ads","Data protection assessments"]','{PRIV-001,PRIV-002}','2023-01-01','https://law.lis.virginia.gov/vacode/title59.1/chapter53/','2026-09-04'),
('US-CO','CPA','Colorado Privacy Act','privacy','Controllers processing data of 100k+ Coloradans, or 25k+ with revenue from data sales.','Privacy notice, opt-out rights including universal opt-out signals, consent for sensitive data, and assessments.','["Privacy notice","Universal opt-out signal support","Consent for sensitive data"]','{PRIV-001,PRIV-002}','2023-07-01','https://coag.gov/resources/colorado-privacy-act/','2026-09-04'),
('US-CT','CTDPA','Connecticut Data Privacy Act','privacy','Controllers processing data of 100k+ Connecticut residents, or 25k+ with 25% revenue from sales.','Privacy notice, opt-out, universal opt-out signals, and protections for minors'' data.','["Privacy notice","Opt-out and GPC support","Minor data protections"]','{PRIV-001,PRIV-002}','2023-07-01','https://portal.ct.gov/ag/sections/privacy/the-connecticut-data-privacy-act','2026-09-04'),
('US-MD','MODPA','Maryland Online Data Privacy Act','privacy','Controllers processing data of 35k+ Marylanders, or 10k+ with 20% revenue from sales.','Strict data minimization, a ban on selling sensitive data, no targeted advertising to under-18s, and assessments.','["Collect only what is strictly necessary","No sale of sensitive data","No targeted ads to minors"]','{PRIV-001,PRIV-002}','2025-10-01','https://mgaleg.maryland.gov/mgawebsite/Legislation/Details/sb0541?ys=2024RS','2026-09-04'),
('US-OR','OCPA','Oregon Consumer Privacy Act','privacy','Controllers processing data of 100k+ Oregonians, or 25k+ with 25% revenue from sales. Nonprofits from July 2025.','Privacy notice, opt-out, the right to receive a list of specific third parties, and universal opt-out signals from 2026.','["Privacy notice","List of specific third parties on request","Universal opt-out from 2026"]','{PRIV-001,PRIV-002,TP-001}','2024-07-01','https://www.doj.state.or.us/consumer-protection/id-theft-data-breaches/privacy/','2026-09-04'),
('US-WA','MHMDA','My Health My Data Act','privacy','Any entity collecting consumer health data (broadly defined, including inferences) about Washingtonians.','Separate consumer health data privacy policy, consent for collection and sharing, geofencing ban near health facilities, and a private right of action.','["Separate health data privacy policy","Consent before collecting health data","No geofencing near health facilities"]','{PRIV-001,PRIV-002}','2024-03-31','https://www.atg.wa.gov/protecting-washingtonians-personal-health-data-and-privacy','2026-09-04'),
('US-FL','FDBR','Florida Digital Bill of Rights','privacy','Controllers over USD 1B revenue meeting platform criteria; minor-data and sensitive-data provisions apply more broadly.','Privacy notice, opt-out, and prohibitions on processing known minors'' data without consent.','["Privacy notice","Opt-out for sale and targeted ads","Consent for minors'' data"]','{PRIV-001,PRIV-002}','2024-07-01','https://www.flsenate.gov/Session/Bill/2023/262','2026-09-04'),
('CA','PIPEDA','Personal Information Protection and Electronic Documents Act','privacy','Commercial organizations collecting personal information in Canada (except AB, BC, QC for provincially regulated activity).','Meaningful consent, openness (privacy policy), access rights, safeguards, and mandatory breach reporting to the OPC.','["Privacy policy explaining purposes","Meaningful consent","Breach reporting to the OPC and records for 24 months"]','{PRIV-001,PRIV-002}','2001-01-01','https://www.priv.gc.ca/en/privacy-topics/privacy-laws-in-canada/the-personal-information-protection-and-electronic-documents-act-pipeda/','2026-09-04'),
('CA','CASL','Canada''s Anti-Spam Legislation','marketing','Any commercial electronic message sent to or from Canada.','Express or implied consent before sending, sender identification, and a working unsubscribe honored within 10 days. Penalties up to CAD 10M.','["Consent records for every recipient","Sender identification in every message","Unsubscribe honored within 10 business days"]','{}','2014-07-01','https://crtc.gc.ca/eng/internet/anti.htm','2026-09-04'),
('CA-ON','AODA','Accessibility for Ontarians with Disabilities Act','accessibility','Organizations with 50+ employees in Ontario; all public sector bodies.','Public websites and web content must conform to WCAG 2.0 AA, with compliance reports filed with the province.','["Conform to WCAG 2.0 AA","File accessibility compliance reports","Accessible feedback process"]','{A11Y-001,A11Y-002,A11Y-003,A11Y-004,A11Y-005,A11Y-006,A11Y-007}','2005-06-13','https://www.ontario.ca/page/how-make-websites-accessible','2026-09-04'),
('CA-QC','Law 25','Act to modernize legislative provisions as regards the protection of personal information (Bill 64)','privacy','Any enterprise collecting personal information of people in Quebec.','Privacy officer, privacy impact assessments, consent for cookies and tracking (opt-in by default from September 2023), breach notification, and portability from 2024.','["Designate a privacy officer","Cookie consent enabled off by default","Privacy impact assessments","Breach notification to the CAI"]','{PRIV-001,PRIV-002}','2023-09-22','https://www.cai.gouv.qc.ca/','2026-09-04'),
('GB','UK GDPR / DPA 2018','UK General Data Protection Regulation and Data Protection Act 2018','privacy','Processing personal data of people in the UK.','Mirrors EU GDPR: lawful basis, privacy notice, data subject rights, 72-hour breach reporting to the ICO, and an ICO registration fee for most organizations.','["Privacy notice","Register with the ICO and pay the data protection fee","Breach reporting within 72 hours"]','{PRIV-001,PRIV-002,PRIV-003}','2021-01-01','https://ico.org.uk/for-organisations/uk-gdpr-guidance-and-resources/','2026-09-04'),
('GB','PECR','Privacy and Electronic Communications Regulations','privacy','Cookies and electronic marketing to UK users.','Consent before non-essential cookies and before marketing emails or texts (with a soft opt-in for existing customers).','["Cookie consent banner","Marketing consent records","Unsubscribe in every message"]','{PRIV-002}','2003-12-11','https://ico.org.uk/for-organisations/direct-marketing-and-privacy-and-electronic-communications/','2026-09-04'),
('GB','Equality Act 2010','Equality Act 2010 (reasonable adjustments)','accessibility','Any service provider in Great Britain.','A duty to make reasonable adjustments so disabled people are not at a substantial disadvantage; inaccessible websites have been the subject of claims. Public bodies must meet WCAG 2.2 AA under the 2018 regulations.','["Conform to WCAG 2.2 AA","Publish an accessibility statement","Provide alternative access routes"]','{A11Y-001,A11Y-002,A11Y-003,A11Y-004,A11Y-005,A11Y-006,A11Y-007}','2010-10-01','https://www.gov.uk/guidance/accessibility-requirements-for-public-sector-websites-and-apps','2026-09-04'),
('AU','Privacy Act 1988','Privacy Act 1988 and the Australian Privacy Principles','privacy','Businesses with AUD 3M+ turnover, all health providers, and any business trading in personal information.','Open and transparent privacy policy, collection notices, cross-border disclosure rules, and the Notifiable Data Breaches scheme.','["APP-compliant privacy policy","Collection notices at point of collection","Notifiable data breach process"]','{PRIV-001,PRIV-002}','1989-01-01','https://www.oaic.gov.au/privacy/privacy-legislation/the-privacy-act','2026-09-04'),
('AU','DDA','Disability Discrimination Act 1992','accessibility','Any provider of goods, services, or facilities in Australia.','Websites must be accessible; the Australian Human Rights Commission points to WCAG 2.1 AA.','["Conform to WCAG 2.1 AA","Accessible alternative on request"]','{A11Y-001,A11Y-002,A11Y-003,A11Y-004,A11Y-005,A11Y-006,A11Y-007}','1993-03-01','https://humanrights.gov.au/our-work/disability-rights/world-wide-web-access-disability-discrimination-act-advisory-notes-ver','2026-09-04'),
('AU','Spam Act','Spam Act 2003','marketing','Commercial electronic messages with an Australian link.','Consent, sender identification, and a functional unsubscribe honored within 5 business days.','["Consent before sending","Sender identification","Unsubscribe within 5 business days"]','{}','2004-04-10','https://www.acma.gov.au/spam','2026-09-04'),
('DE','TDDDG','Telekommunikation-Digitale-Dienste-Datenschutz-Gesetz (cookie consent)','privacy','Any site storing information on devices of users in Germany.','Consent before cookies and similar technologies, enforced by the state DPAs with a strict reading of "equally easy to reject".','["Consent management platform","Reject as easy as accept"]','{PRIV-002}','2021-12-01','https://www.gesetze-im-internet.de/ttdsg/','2026-09-04'),
('DE','BFSG','Barrierefreiheitsstaerkungsgesetz','accessibility','Consumer-facing e-commerce and digital services in Germany from 28 June 2025 (microenterprise exemption for services).','Implements the European Accessibility Act. Requires EN 301 549 conformance and an accessibility statement.','["Conform to WCAG 2.1 AA","Publish an accessibility statement (Erklaerung zur Barrierefreiheit)"]','{A11Y-001,A11Y-002,A11Y-003,A11Y-004,A11Y-005,A11Y-006,A11Y-007}','2025-06-28','https://www.gesetze-im-internet.de/bfsg/','2026-09-04'),
('DE','Impressumspflicht','Legal notice duty (DDG Section 5)','consumer','Every commercial website in Germany.','A legal notice with company name, address, contact, register number, and VAT ID, reachable within two clicks.','["Impressum page linked from every page"]','{}','2007-03-01','https://www.gesetze-im-internet.de/ddg/','2026-09-04'),
('BR','LGPD','Lei Geral de Protecao de Dados Pessoais','privacy','Any processing of personal data of individuals located in Brazil.','Legal basis for processing, privacy notice, data subject rights, DPO (encarregado), and incident reporting to the ANPD.','["Privacy notice in Portuguese","Appoint an encarregado","Incident reporting to the ANPD"]','{PRIV-001,PRIV-002}','2020-09-18','https://www.gov.br/anpd/','2026-09-04'),
('IN','DPDP Act','Digital Personal Data Protection Act 2023','privacy','Processing digital personal data in India, or outside India when offering goods or services to Indian users.','Notice and consent, purpose limitation, breach notification to the Data Protection Board, and verifiable parental consent for children.','["Consent notice in plain language","Breach notification","Parental consent for minors"]','{PRIV-001,PRIV-002}','2023-08-11','https://www.meity.gov.in/data-protection-framework','2026-09-04'),
('SG','PDPA','Personal Data Protection Act 2012','privacy','Organizations collecting personal data in Singapore.','Consent, purpose notification, access and correction, mandatory breach notification to the PDPC, and Do Not Call registry compliance.','["Privacy policy and consent","Breach notification within 3 days of assessment","Check the Do Not Call registry"]','{PRIV-001,PRIV-002}','2014-07-02','https://www.pdpc.gov.sg/','2026-09-04'),
('JP','APPI','Act on the Protection of Personal Information','privacy','Business operators handling personal information of people in Japan, including foreign operators.','Purpose specification, consent for third-party provision and cross-border transfer, breach reporting to the PPC, and opt-out records.','["Publish purpose of use","Consent for third-party sharing","Report breaches to the PPC"]','{PRIV-001,PRIV-002}','2005-04-01','https://www.ppc.go.jp/en/','2026-09-04'),
('ZA','POPIA','Protection of Personal Information Act','privacy','Any responsible party processing personal information in South Africa.','Lawful processing conditions, Information Officer registration, direct marketing opt-in, and breach notification to the Information Regulator.','["Register an Information Officer","Privacy policy (PAIA manual)","Opt-in for direct marketing"]','{PRIV-001,PRIV-002}','2021-07-01','https://inforegulator.org.za/','2026-09-04'),
('CH','nFADP','Federal Act on Data Protection (revised 2023)','privacy','Any processing of personal data of people in Switzerland.','Privacy policy, records of processing (250+ staff), breach notification to the FDPIC, and a Swiss representative for foreign controllers.','["Privacy policy","Breach notification","Swiss representative where required"]','{PRIV-001,PRIV-002}','2023-09-01','https://www.edoeb.admin.ch/','2026-09-04'),
('NO','Universal Design regulation','Regulation on universal design of ICT solutions','accessibility','All websites serving the public in Norway, private and public sector.','WCAG 2.1 AA conformance is mandatory, enforced by the Authority for Universal Design of ICT with fines.','["Conform to WCAG 2.1 AA","Publish an accessibility statement (public sector)"]','{A11Y-001,A11Y-002,A11Y-003,A11Y-004,A11Y-005,A11Y-006,A11Y-007}','2014-07-01','https://www.uutilsynet.no/english/','2026-09-04')
on conflict (jurisdiction_code, short_name) do update set full_name = excluded.full_name, category = excluded.category,
  applies_when = excluded.applies_when, summary = excluded.summary, obligations = excluded.obligations,
  rule_ids = excluded.rule_ids, effective_date = excluded.effective_date, reference_url = excluded.reference_url,
  reviewed_at = excluded.reviewed_at;

------------------------------------------------------------------------------
-- White-label brand profiles (org default, optional per-website override)
------------------------------------------------------------------------------
create table if not exists muster.brand_profiles (
  id                     bigint generated by default as identity primary key,
  organization_id        bigint not null references muster.organizations(id) on delete cascade,
  website_id             bigint references muster.websites(id) on delete cascade,
  brand_name             varchar(80) not null,
  brand_mark             varchar(4) not null,
  eyebrow                varchar(80) not null default 'Website Assurance',
  primary_color          char(7) not null default '#36e2c9' check (primary_color ~ '^#[0-9a-fA-F]{6}$'),
  accent_color           char(7) not null default '#f5b942' check (accent_color ~ '^#[0-9a-fA-F]{6}$'),
  logo_url               varchar(1024),
  favicon_url            varchar(1024),
  custom_domain          varchar(253),
  support_email          varchar(320),
  support_url            varchar(1024),
  report_disclaimer      text not null default 'Prepared under the MUSTER Assurance Framework by 28 Foot Systems. All rights reserved.',
  report_signoff_name    varchar(120),
  report_signoff_title   varchar(120),
  welcome_message        text,
  tone                   varchar(16) not null default 'executive' check (tone in ('executive','plain','technical')),
  locale                 varchar(10) not null default 'en-US',
  hide_muster_attribution boolean not null default false,
  created_by_id          bigint references muster.users(id),
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now()
);
create unique index if not exists brand_profiles_org_default_idx on muster.brand_profiles (organization_id) where website_id is null;
create unique index if not exists brand_profiles_website_idx on muster.brand_profiles (website_id) where website_id is not null;
create or replace trigger brand_profiles_touch before update on muster.brand_profiles
  for each row execute function muster.touch_updated_at();

create table if not exists muster.user_preferences (
  user_id                 bigint primary key references muster.users(id) on delete cascade,
  theme                   varchar(8) not null default 'system' check (theme in ('system','dark','light')),
  density                 varchar(12) not null default 'comfortable' check (density in ('comfortable','compact')),
  default_organization_id bigint references muster.organizations(id) on delete set null,
  default_view            varchar(32) not null default 'executive',
  digest_cadence          varchar(8) not null default 'weekly' check (digest_cadence in ('off','daily','weekly')),
  notify_channel          varchar(12) not null default 'email' check (notify_channel in ('email','telegram','none')),
  telegram_chat_id        varchar(32),
  preferred_name          varchar(80),
  updated_at              timestamptz not null default now()
);
create or replace trigger user_preferences_touch before update on muster.user_preferences
  for each row execute function muster.touch_updated_at();

------------------------------------------------------------------------------
-- Feature flags (super admin controlled)
------------------------------------------------------------------------------
create table if not exists muster.feature_flags (
  key              varchar(48) primary key,
  name             varchar(96) not null,
  description      text not null,
  scope            varchar(16) not null default 'organization' check (scope in ('platform','organization','user')),
  default_enabled  boolean not null default false,
  plan_minimum     varchar(16) references muster.plans(plan),
  kill_switch      boolean not null default false,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create or replace trigger feature_flags_touch before update on muster.feature_flags
  for each row execute function muster.touch_updated_at();

create table if not exists muster.feature_flag_overrides (
  id               bigint generated by default as identity primary key,
  flag_key         varchar(48) not null references muster.feature_flags(key) on delete cascade,
  organization_id  bigint references muster.organizations(id) on delete cascade,
  user_id          bigint references muster.users(id) on delete cascade,
  enabled          boolean not null,
  reason           text,
  set_by_id        bigint references muster.users(id),
  expires_at       timestamptz,
  created_at       timestamptz not null default now(),
  check (organization_id is not null or user_id is not null)
);
create unique index if not exists feature_flag_overrides_org_idx on muster.feature_flag_overrides (flag_key, organization_id) where user_id is null;
create unique index if not exists feature_flag_overrides_user_idx on muster.feature_flag_overrides (flag_key, user_id) where user_id is not null;

insert into muster.feature_flags (key, name, description, scope, default_enabled, plan_minimum) values
('manual_scans','Manual scans','Members can request an on-demand scan from the workspace.','organization',true,'trial'),
('scheduled_scans','Scheduled scans','pg_cron runs scans on the website cadence.','organization',true,'trial'),
('sitrep_generation','SITREP generation','Deterministic, fully cited SITREP after every completed scan.','organization',true,'trial'),
('jurisdiction_advisor','Jurisdiction advisor','Law advisories by country and state, with obligations mapped to scan evidence.','organization',true,'trial'),
('white_label','White-label branding','Custom brand name, mark, colors, logo, and report disclaimer.','organization',true,'starter'),
('custom_domain','Custom domain','Serve the workspace from the client''s own domain.','organization',false,'pro'),
('hide_attribution','Hide MUSTER attribution','Remove the "Prepared by MUSTER" line from reports.','organization',false,'pro'),
('agent_api','Agent API (MCP)','Issue API keys for AI agents and integrations via the muster-agent endpoint.','organization',true,'pro'),
('promote_finding_to_risk','Promote finding to risk register','One-click promotion of a scanner finding into the risk register with evidence links.','organization',true,'trial'),
('multi_website','Multiple websites','Allow more than one website per organization (limit from plan).','organization',true,'starter'),
('browser_wcag_engine','Browser WCAG engine','Headless-browser accessibility engine (axe-core) for full WCAG coverage. Not yet built.','platform',false,'pro'),
('ai_narrative','AI narrative SITREP','LLM-written executive narrative constrained to cited claims. Not yet built.','platform',false,'pro'),
('telegram_alerts','Telegram alerts','Critical finding alerts to Telegram (CORA relay).','organization',false,'starter'),
('pdf_export','PDF export','Server-rendered SITREP PDF. Not yet built.','platform',false,'starter'),
('public_status_badge','Public assurance badge','Public posture badge and status page per website. Not yet built.','platform',false,'pro'),
('self_serve_onboarding','Self-serve onboarding','New users can create an organization and first website without a human.','platform',true,null),
('super_admin_console','Super admin console','Platform console: tenants, plans, flags, agents, jurisdiction review queue.','platform',true,null)
on conflict (key) do update set name = excluded.name, description = excluded.description, scope = excluded.scope,
  default_enabled = excluded.default_enabled, plan_minimum = excluded.plan_minimum;

-- Kill switches on for features that are declared but not built.
update muster.feature_flags set kill_switch = true where key in ('browser_wcag_engine','ai_narrative','pdf_export','public_status_badge');

------------------------------------------------------------------------------
-- Agents and API keys (AI employee / integration identities)
------------------------------------------------------------------------------
create table if not exists muster.agents (
  id               bigint generated by default as identity primary key,
  organization_id  bigint references muster.organizations(id) on delete cascade,  -- null = platform agent (28FS internal)
  name             varchar(80) not null,
  kind             varchar(24) not null check (kind in ('internal_employee','customer_agent','integration')),
  description      text,
  created_by_id    bigint references muster.users(id),
  active           boolean not null default true,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create or replace trigger agents_touch before update on muster.agents
  for each row execute function muster.touch_updated_at();

create table if not exists muster.api_keys (
  id               bigint generated by default as identity primary key,
  agent_id         bigint not null references muster.agents(id) on delete cascade,
  organization_id  bigint references muster.organizations(id) on delete cascade,  -- null = platform scope
  name             varchar(80) not null,
  key_prefix       char(12) not null,
  key_hash         char(64) not null unique,
  scopes           text[] not null default '{read}',
  created_by_id    bigint references muster.users(id),
  last_used_at     timestamptz,
  expires_at       timestamptz,
  revoked_at       timestamptz,
  created_at       timestamptz not null default now()
);
create index if not exists api_keys_agent_idx on muster.api_keys (agent_id);

alter table muster.scans drop constraint if exists scans_requested_by_agent_fk;
alter table muster.scans add constraint scans_requested_by_agent_fk
  foreign key (requested_by_agent_id) references muster.agents(id);
alter table muster.activity_events drop constraint if exists activity_events_agent_fk;
alter table muster.activity_events add constraint activity_events_agent_fk
  foreign key (agent_id) references muster.agents(id);

------------------------------------------------------------------------------
-- Engine secret (used by cron, the request_scan RPC, and the edge functions)
------------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from vault.secrets where name = 'muster_cron_secret') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'muster_cron_secret',
      'MUSTER engine shared secret: pg_cron and RPC -> muster-scan edge function');
  end if;
end $$;

