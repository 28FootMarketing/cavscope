// The rules that read a page's HTML and nothing else: accessibility, privacy and
// terms links, trackers, script integrity, mixed content, insecure forms, meta
// description, canonical, structured data, and client-rendered shells.
//
// Pure: no fetch, no database, no Deno globals. Two callers run this exact code
// -- the scan engine (cavscope-scan/index.ts), which records each step as a
// finding or an evidence excerpt, and the HTML audit (cavscope-html-audit),
// which runs it on HTML pasted into the admin console for a site CavScope does
// not scan. Moved here verbatim on 2026-09-30; the engine's findings and
// evidence on the same page were compared before and after the move and are
// identical, so no ENGINE_VERSION change. Rules that need the live server
// (headers, cookies, redirects, DNS, robots.txt, availability) stay in index.ts
// and cannot run on pasted HTML at all.

import { detectClientRendered, stripTags } from "./html.ts";
import { evaluateSubresourceIntegrity, extractScripts, type HardeningFinding } from "./hardening.ts";
import { summarizeJsonLd } from "./aio.ts";

export type PageFinding = HardeningFinding;

/** One thing the engine does, in order: raise a finding, or record an excerpt. */
export type PageStep =
  | { kind: "finding"; finding: PageFinding }
  | { kind: "snippet"; key: string; label: string; tags: string[] }
  | { kind: "jsonld"; text: string };

export function attr(tag: string, name: string): string | null {
  const m = tag.match(new RegExp(`\\s${name}\\s*=\\s*("([^"]*)"|'([^']*)'|([^\\s>]+))`, "i"));
  if (!m) return null;
  return (m[2] ?? m[3] ?? m[4] ?? "").trim();
}
export function hasAttr(tag: string, name: string) { return new RegExp(`\\s${name}(\\s|=|>|/)`, "i").test(tag); }

export const TRACKER_HOSTS: Array<[RegExp, string]> = [
  [/googletagmanager\.com/i, "Google Tag Manager"],
  [/google-analytics\.com|analytics\.google\.com/i, "Google Analytics"],
  [/doubleclick\.net|googleadservices\.com|googlesyndication\.com/i, "Google Ads"],
  [/connect\.facebook\.net|facebook\.com\/tr/i, "Meta Pixel"],
  [/hotjar\.com/i, "Hotjar"],
  [/clarity\.ms/i, "Microsoft Clarity"],
  [/tiktok\.com\/i18n|analytics\.tiktok\.com/i, "TikTok Pixel"],
  [/snap\.licdn\.com|linkedin\.com\/px/i, "LinkedIn Insight"],
  [/static\.ads-twitter\.com/i, "X (Twitter) Pixel"],
  [/fullstory\.com/i, "FullStory"],
  [/segment\.com|segment\.io/i, "Segment"],
  [/hubspot\.com|hs-scripts\.com|hs-analytics\.net/i, "HubSpot"],
  [/mixpanel\.com/i, "Mixpanel"],
  [/amplitude\.com/i, "Amplitude"],
  [/pinimg\.com|pinterest\.com\/ct/i, "Pinterest Tag"],
  [/leadconnectorhq\.com|msgsndr\.com/i, "GoHighLevel"],
];

/**
 * The content rules: language, title, alt text, zoom, heading, labels, link
 * text, privacy and terms links. Also returns the anchors the engine's
 * jurisdiction step reads next, so it does not parse them twice.
 */
export function contentChecks(html: string) {
  const steps: PageStep[] = [];
  const add = (finding: PageFinding) => steps.push({ kind: "finding", finding });
  const snip = (key: string, label: string, tags: string[]) => steps.push({ kind: "snippet", key, label, tags });

  // Client-rendered apps ship almost no markup; content rules then carry low confidence until the browser engine runs.
  const clientRendered = detectClientRendered(html);
  const csrNote = clientRendered ? " The page appears to render client-side; the HTTP engine only sees the initial HTML. Confirm with the browser engine." : "";
  const csrConf = (c: "high" | "medium" | "low") => (clientRendered ? "low" : c);

  const htmlTag = html.match(/<html\b[^>]*>/i)?.[0] ?? "";
  if (!htmlTag || !attr(htmlTag, "lang")) {
    add({ rule_id: "A11Y-001", severity: "medium", title: "Page language not declared", detail: htmlTag ? `The html element is "${htmlTag.slice(0, 120)}" with no lang attribute.` : "No html element with a lang attribute was found.", location: "<html>", confidence: "high", evidence_keys: ["primary"] });
  }
  const title = html.match(/<title\b[^>]*>([\s\S]*?)<\/title>/i);
  if (!title || !stripTags(title[1])) add({ rule_id: "A11Y-002", severity: "medium", title: "Page title missing or empty", detail: "No non-empty <title> element was found in the document head.", location: "<title>", confidence: "high", evidence_keys: ["primary"] });

  const imgs = html.match(/<img\b[^>]*>/gi) ?? [];
  const noAlt = imgs.filter((t) => !hasAttr(t, "alt") && !/\srole\s*=\s*["']?presentation/i.test(t) && !/\saria-hidden\s*=\s*["']?true/i.test(t));
  if (noAlt.length) {
    snip("img_alt", `${noAlt.length} of ${imgs.length} img elements have no alt attribute:`, noAlt);
    add({ rule_id: "A11Y-003", severity: "medium", title: "Images missing alternative text", detail: `${noAlt.length} of ${imgs.length} images on the homepage have no alt attribute.`, location: "<img>", confidence: "high", evidence_keys: ["img_alt", "primary"] });
  }
  const viewport = (html.match(/<meta\b[^>]*name\s*=\s*["']viewport["'][^>]*>/i) ?? [])[0];
  if (viewport) {
    const content = attr(viewport, "content") ?? "";
    const maxScale = content.match(/maximum-scale\s*=\s*([\d.]+)/i);
    if (/user-scalable\s*=\s*(no|0)/i.test(content) || (maxScale && parseFloat(maxScale[1]) < 2)) {
      add({ rule_id: "A11Y-004", severity: "medium", title: "Pinch zoom disabled", detail: `Viewport meta content is "${content}".`, location: "<meta name=viewport>", confidence: "high", evidence_keys: ["primary"] });
    }
  }
  if (!/<h1\b/i.test(html)) add({ rule_id: "A11Y-005", severity: "low", title: "No top-level heading", detail: "No <h1> element was found on the homepage." + csrNote, location: "<h1>", confidence: csrConf("high"), evidence_keys: ["primary"] });

  // Form field labels
  const labelFor = new Set<string>();
  for (const m of html.matchAll(/<label\b[^>]*>/gi)) { const f = attr(m[0], "for"); if (f) labelFor.add(f); }
  const labelSpans: Array<[number, number]> = [];
  for (const m of html.matchAll(/<label\b[^>]*>[\s\S]*?<\/label>/gi)) labelSpans.push([m.index!, m.index! + m[0].length]);
  const unlabeled: string[] = [];
  for (const m of html.matchAll(/<(input|select|textarea)\b[^>]*>/gi)) {
    const t = m[0];
    const type = (attr(t, "type") ?? "text").toLowerCase();
    if (m[1].toLowerCase() === "input" && ["hidden", "submit", "button", "reset", "image"].includes(type)) continue;
    if (hasAttr(t, "aria-label") || hasAttr(t, "aria-labelledby") || hasAttr(t, "title")) continue;
    const id = attr(t, "id");
    if (id && labelFor.has(id)) continue;
    const idx = m.index!;
    if (labelSpans.some(([a, b]) => idx > a && idx < b)) continue;
    unlabeled.push(t);
  }
  if (unlabeled.length) {
    snip("form_labels", `${unlabeled.length} form fields with no label, aria-label, or aria-labelledby:`, unlabeled);
    add({ rule_id: "A11Y-006", severity: "medium", title: "Form fields without an accessible label", detail: `${unlabeled.length} form field(s) have no associated label. Placeholder text alone is not a label.` + csrNote, location: "<input>/<select>/<textarea>", confidence: csrConf("medium"), evidence_keys: ["form_labels", "primary"] });
  }
  // Empty links
  const emptyLinks: string[] = [];
  for (const m of html.matchAll(/<a\b[^>]*>([\s\S]*?)<\/a>/gi)) {
    const open = m[0].match(/^<a\b[^>]*>/i)?.[0] ?? "";
    const inner = m[1];
    if (hasAttr(open, "aria-label") || hasAttr(open, "aria-labelledby") || hasAttr(open, "title")) continue;
    if (stripTags(inner)) continue;
    if (/<img\b[^>]*\salt\s*=\s*["'][^"']+["']/i.test(inner)) continue;
    if (/<svg\b/i.test(inner)) continue; // handled by the browser engine later
    if (/aria-hidden\s*=\s*["']?true/i.test(open)) continue;
    emptyLinks.push(m[0]);
  }
  if (emptyLinks.length) {
    snip("empty_links", `${emptyLinks.length} links with no discernible text:`, emptyLinks);
    add({ rule_id: "A11Y-007", severity: "medium", title: "Links with no discernible text", detail: `${emptyLinks.length} link(s) have no text, aria-label, or image alt text.` + csrNote, location: "<a>", confidence: csrConf("medium"), evidence_keys: ["empty_links", "primary"] });
  }

  // Privacy policy link
  const anchors = [...html.matchAll(/<a\b[^>]*>([\s\S]*?)<\/a>/gi)];
  const privacyHref = (m: RegExpMatchArray) => attr(m[0].match(/^<a\b[^>]*>/i)?.[0] ?? "", "href") ?? "";
  const privacy = anchors.some((m) => /privacy/i.test(privacyHref(m)) || /privacy/i.test(stripTags(m[1])));
  if (!privacy) add({ rule_id: "PRIV-001", severity: clientRendered ? "low" : "medium", title: "No privacy policy link found", detail: `Scanned ${anchors.length} links on the homepage; none contained "privacy" in its text or href.` + csrNote, location: "homepage links", confidence: csrConf("medium"), evidence_keys: ["primary"] });

  // Terms of Service link, credited the same way PRIV-001 credits a privacy
  // policy: presence in an anchor's text or href is enough. Word-boundaried
  // so "terminal" or "terminate" do not match "term".
  const termsAnchor = anchors.find((m) => /\bterms\b|\btos\b/i.test(privacyHref(m)) || /\bterms\b|\btos\b/i.test(stripTags(m[1])));
  if (!termsAnchor) add({ rule_id: "PRIV-004", severity: "low", title: "No Terms of Service link found", detail: `Scanned ${anchors.length} links on the homepage; none contained "terms" or "tos" in its text or href.` + csrNote, location: "homepage links", confidence: csrConf("medium"), evidence_keys: ["primary"] });

  return { steps, clientRendered, anchors, privacy, termsAnchor, privacyHref };
}

/**
 * The resource rules: external scripts (TP-001, SEC-014, PRIV-002), mixed
 * content (SEC-010, only when the page is served over https), insecure forms
 * (PRIV-003), and the head and AIO rules (GOV-003, GOV-005, GOV-007, GOV-008).
 * `host` is the hostname only, for same-site comparisons.
 */
export function resourceChecks(html: string, ctx: { finalUrl: string; host: string; isHttps: boolean; clientRendered: boolean }) {
  const { finalUrl, host, isHttps, clientRendered } = ctx;
  const steps: PageStep[] = [];
  const add = (finding: PageFinding) => steps.push({ kind: "finding", finding });
  const snip = (key: string, label: string, tags: string[]) => steps.push({ kind: "snippet", key, label, tags });
  const csrNote = clientRendered ? " The page appears to render client-side; the HTTP engine only sees the initial HTML. Confirm with the browser engine." : "";
  const csrConf = (c: "high" | "medium" | "low") => (clientRendered ? "low" : c);

  // Scripts, trackers, mixed content
  const scriptSrcs = [...html.matchAll(/<script\b[^>]*\ssrc\s*=\s*["']([^"']+)["']/gi)].map((m) => m[1]);
  const external = scriptSrcs.map((s) => { try { return new URL(s, finalUrl); } catch { return null; } }).filter((u): u is URL => !!u && u.hostname.toLowerCase() !== host);
  const extHosts = [...new Set(external.map((u) => u.hostname.toLowerCase()))];
  if (extHosts.length) {
    snip("scripts", `External script hosts (${extHosts.length}):`, extHosts.map((hn) => hn + "  <- " + external.filter((u) => u.hostname.toLowerCase() === hn).map((u) => u.pathname).slice(0, 3).join(", ")));
    add({ rule_id: "TP-001", severity: "info", title: "External script inventory", detail: `${external.length} external script(s) from ${extHosts.length} host(s): ${extHosts.slice(0, 15).join(", ")}${extHosts.length > 15 ? ", ..." : ""}.`, location: "<script src>", confidence: "high", evidence_keys: ["scripts"] });
    const trackers = [...new Set(TRACKER_HOSTS.filter(([re]) => external.some((u) => re.test(u.href)) || re.test(html)).map(([, n]) => n))];
    // SEC-014 reads the same scripts TP-001 inventoried, but off the whole tag
    // rather than the src, because integrity and crossorigin live there.
    for (const f of evaluateSubresourceIntegrity({
      scripts: extractScripts(html, finalUrl, host),
      evidenceKey: "scripts",
    })) add(f);
    if (trackers.length) add({ rule_id: "PRIV-002", severity: "low", title: "Third-party trackers loaded before consent could be verified", detail: `Detected: ${trackers.join(", ")}. The HTTP engine cannot see whether a consent banner gates these tags; verify in the browser engine or manually.`, location: "<script src>", confidence: "medium", evidence_keys: ["scripts"] });
  }
  if (isHttps) {
    const mixed: string[] = [];
    for (const m of html.matchAll(/<(script|link|img|iframe|video|audio|source|embed|object)\b[^>]*>/gi)) {
      const t = m[0];
      const src = attr(t, "src") ?? attr(t, "href") ?? attr(t, "data");
      if (!src || !/^http:\/\//i.test(src)) continue;
      if (m[1].toLowerCase() === "link" && !/stylesheet|icon|preload|modulepreload/i.test(attr(t, "rel") ?? "")) continue;
      mixed.push(t);
    }
    if (mixed.length) {
      snip("mixed", `${mixed.length} insecure (http://) resource references on an HTTPS page:`, mixed);
      add({ rule_id: "SEC-010", severity: "high", title: "Mixed content on an HTTPS page", detail: `${mixed.length} resource(s) are referenced over plain http:// from the HTTPS homepage.`, location: "resource references", confidence: "high", evidence_keys: ["mixed", "primary"] });
    }
  }
  // Forms
  const badForms: string[] = [];
  for (const m of html.matchAll(/<form\b[^>]*>/gi)) {
    const action = attr(m[0], "action");
    if (!action) continue;
    let u: URL | null = null; try { u = new URL(action, finalUrl); } catch { continue; }
    if (u.protocol === "http:" || (u.hostname.toLowerCase() !== host && !u.hostname.toLowerCase().endsWith("." + host))) badForms.push(m[0]);
  }
  if (badForms.length) {
    snip("forms", `${badForms.length} forms posting over http:// or to an external host:`, badForms);
    add({ rule_id: "PRIV-003", severity: "medium", title: "Form submits to an insecure or external endpoint", detail: `${badForms.length} form(s) post to http:// or to a domain other than ${host}.`, location: "<form action>", confidence: "medium", evidence_keys: ["forms"] });
  }
  // Governance / AIO
  if (!/<meta\b[^>]*name\s*=\s*["']description["']/i.test(html)) add({ rule_id: "GOV-003", severity: "info", title: "Meta description missing", detail: "No <meta name=\"description\"> on the homepage.", location: "<head>", confidence: "high", evidence_keys: ["primary"] });
  if (!/<link\b[^>]*rel\s*=\s*["']canonical["']/i.test(html)) add({ rule_id: "GOV-005", severity: "info", title: "Canonical link missing", detail: "No <link rel=\"canonical\"> on the homepage.", location: "<head>", confidence: "high", evidence_keys: ["primary"] });
  // GOV-007: structured data. The summary is written as evidence on every HTML
  // scan, pass or fail, so a scan on this engine is provable even where the rule
  // is silent -- the same role dns_spf_chain plays for EMAIL-009.
  const ld = summarizeJsonLd(html);
  const ldText = `JSON-LD blocks: ${ld.blocks}; parsed: ${ld.parsed}; types: ${ld.types.length ? ld.types.join(", ") : "none"}`;
  steps.push({ kind: "jsonld", text: ldText });
  if (ld.parsed === 0) {
    add({ rule_id: "GOV-007", severity: "info", title: "No readable structured data (JSON-LD)",
      detail: (ld.blocks ? `${ld.blocks} application/ld+json block(s) on the homepage, none of which parse as JSON, so no crawler can read them.` : "The served homepage has no application/ld+json block, so nothing states machine-readably what organization, product or service the site represents.") + csrNote,
      location: "<script type=\"application/ld+json\">", confidence: csrConf("high"), evidence_keys: ["jsonld", "primary"] });
  }
  // GOV-008: the page an AI crawler receives. GPTBot, ClaudeBot and PerplexityBot
  // read the served HTML and do not run the site's JavaScript, so a client-rendered
  // homepage reaches them as an empty shell. Medium confidence because
  // detectClientRendered is a text-length heuristic, not a render comparison.
  if (clientRendered) {
    add({ rule_id: "GOV-008", severity: "low", title: "Homepage content is rendered by script, not served",
      detail: "The served homepage carries almost no readable text and loads script, so its content is built in the browser. Crawlers that do not execute JavaScript, which includes the main AI crawlers, receive the empty shell rather than the page a visitor sees.",
      location: "<body>", confidence: "medium", evidence_keys: ["primary"] });
  }
  return steps;
}
