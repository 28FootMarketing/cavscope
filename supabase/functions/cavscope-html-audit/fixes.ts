// The HTML audit's pure half: run the scan engine's page rules on pasted HTML,
// describe how each finding is fixed, and apply the fixes the operator chose.
//
// No fetch, no database, no Deno globals, so tests/html-audit/ runs this exact
// code. The rules themselves are not here: they are muster-scan/page-checks.ts,
// the same module the scan engine runs, so a finding here and a finding on a
// scanned site can never disagree about what they mean.
//
// Three kinds of fix, and the line between them is deliberate:
//   auto   - mechanical and safe to apply without judgment (a language code,
//            removing a zoom block, http -> https, an integrity hash)
//   input  - the fix needs words only a person can supply (alt text, a title,
//            a description, a label). Never guessed: invented alt text under
//            CavScope's name is an accessibility defect we would be shipping.
//   manual - cannot be fixed in the HTML (a consent banner, server rendering)
// Every finding also carries plain instructions, because most small-business
// sites are built on a platform (WordPress, Wix, Squarespace, Shopify) where a
// fixed HTML file cannot simply be put back.

import { contentChecks, resourceChecks, attr, type PageFinding, type PageStep } from "../muster-scan/page-checks.ts";
import { extractScripts, isMutableByDesign } from "../muster-scan/hardening.ts";

export const MAX_HTML_BYTES = 2_000_000;

export type AuditContext = { finalUrl: string; host: string; isHttps: boolean; assumed: boolean };

/** Where the page lives. Without an address, assume https on an unknown host, and say so. */
export function contextFor(pageUrl: string | null | undefined): AuditContext {
  if (pageUrl) {
    try {
      const u = new URL(pageUrl);
      if (u.protocol === "https:" || u.protocol === "http:") {
        return { finalUrl: u.toString(), host: u.hostname.toLowerCase(), isHttps: u.protocol === "https:", assumed: false };
      }
    } catch { /* fall through */ }
  }
  return { finalUrl: "https://site.invalid/", host: "site.invalid", isHttps: true, assumed: true };
}

export type Targets = { img_alt: string[]; form_labels: string[]; empty_links: string[]; mixed: string[]; forms: string[] };

export type AuditResult = {
  findings: PageFinding[];
  targets: Targets;
  clientRendered: boolean;
  context: AuditContext;
};

/** Runs the engine's own page rules and keeps the offending tags each one names. */
export function audit(html: string, pageUrl?: string | null): AuditResult {
  const context = contextFor(pageUrl);
  const page = contentChecks(html);
  const steps: PageStep[] = [...page.steps, ...resourceChecks(html, { finalUrl: context.finalUrl, host: context.host, isHttps: context.isHttps, clientRendered: page.clientRendered })];
  const targets: Targets = { img_alt: [], form_labels: [], empty_links: [], mixed: [], forms: [] };
  const findings: PageFinding[] = [];
  for (const s of steps) {
    if (s.kind === "finding") findings.push(s.finding);
    else if (s.kind === "snippet" && s.key in targets) targets[s.key as keyof Targets] = s.tags;
  }
  return { findings, targets, clientRendered: page.clientRendered, context };
}

export type FixMode = "auto" | "input" | "manual";
export type FixInfo = { mode: FixMode; does: string; howTo: string };

// What each page rule's fix is, and how to make it on a site built on a platform.
export const FIXES: Record<string, FixInfo> = {
  "A11Y-001": { mode: "auto", does: "Adds a lang attribute to the <html> element in the language you pick.",
    howTo: "Most platforms set this from the site language setting: WordPress Settings > General > Site Language; Wix, Squarespace and Shopify use the site or store language. On a hand-built site add lang=\"en\" (or the page's language) to the <html> tag." },
  "A11Y-002": { mode: "input", does: "Sets the page title to the text you enter.",
    howTo: "Set the page's SEO title in the page settings (WordPress: the page title, or the SEO plugin's title field; Wix, Squarespace, Shopify: the page's SEO settings)." },
  "A11Y-003": { mode: "input", does: "Adds the alt text you write to each image. Mark an image decorative to give it an empty alt, which tells screen readers to skip it.",
    howTo: "Open each image in the media library or image block and fill in its Alt text field. Describe what the image shows or does; leave it empty only for purely decorative images." },
  "A11Y-004": { mode: "auto", does: "Removes user-scalable=no and any maximum-scale below 2 from the viewport tag, so visitors can pinch to zoom.",
    howTo: "This lives in the theme's header template. In WordPress, edit the theme (or a child theme) header.php viewport tag, or ask the theme vendor; hosted builders rarely block zoom, so if they do, contact support." },
  "A11Y-005": { mode: "manual", does: "Not changed automatically: where a page's main heading belongs depends on its layout.",
    howTo: "Make the page's main headline a Heading 1 in the editor (one per page). In most builders select the headline text and choose Heading 1 / H1 from the text style menu." },
  "A11Y-006": { mode: "input", does: "Adds an accessible name (aria-label) you write to each unlabeled form field.",
    howTo: "In the form builder, give every field a visible label, not only placeholder text. Most form plugins have a Label setting per field; turn off \"hide label\" if it is on." },
  "A11Y-007": { mode: "input", does: "Adds an accessible name (aria-label) you write to each link that has no text.",
    howTo: "Icon-only links (social icons, a logo, arrows) need a text label. Most builders have a link or icon \"accessible name\" or \"label\" field; otherwise add visually hidden text." },
  "PRIV-001": { mode: "input", does: "Adds a Privacy Policy link, to the address you give, into the page footer.",
    howTo: "Publish a privacy policy page and link it from the site footer (WordPress: Settings > Privacy creates one; add it to the footer menu)." },
  "PRIV-004": { mode: "input", does: "Adds a Terms of Service link, to the address you give, into the page footer.",
    howTo: "Publish a terms page and link it from the site footer menu." },
  "PRIV-002": { mode: "manual", does: "Not changed automatically: the fix is a consent banner that holds these tags until a visitor agrees.",
    howTo: "Install a consent management tool (for example the platform's built-in cookie banner, or a consent plugin) and set the analytics and advertising tags to load only after consent." },
  "PRIV-003": { mode: "auto", does: "Changes form actions from http:// to https://. A form posting to a different website is listed but not changed, because only you know whether that service is intended.",
    howTo: "In the form builder's submission settings, make sure the form posts over https and to a service you intend. Replace any http:// endpoint with its https:// address." },
  "SEC-010": { mode: "auto", does: "Changes images, scripts and stylesheets referenced over http:// to https://. Check afterwards that each one still loads: a server with no https version will break.",
    howTo: "Find the http:// links in the page content or theme settings and change them to https://. WordPress sites often need a search-and-replace plugin after moving to https." },
  "SEC-014": { mode: "auto", does: "Adds an integrity hash and crossorigin=\"anonymous\" to the outside scripts you tick. Only tick scripts pinned to a version: a script that changes at its address will stop loading once hashed.",
    howTo: "Add integrity and crossorigin attributes to third-party script tags where your platform allows custom code; many hosted builders do not, and then the practical fix is to load fewer outside scripts." },
  "TP-001": { mode: "manual", does: "An inventory, not a defect: every outside script is code another company can change on your site.",
    howTo: "Review the list and remove scripts nobody uses (old analytics, abandoned chat widgets). Most platforms list them under integrations, apps or custom code." },
  "GOV-003": { mode: "input", does: "Adds a meta description with the text you enter.",
    howTo: "Fill in the page's SEO or search description (WordPress: an SEO plugin's meta description; Wix, Squarespace, Shopify: the page's SEO settings)." },
  "GOV-005": { mode: "auto", does: "Adds a canonical link pointing at the page's own address.",
    howTo: "Most SEO plugins and hosted builders add canonical tags automatically; turn that setting on. On a hand-built site add <link rel=\"canonical\" href=\"(this page's address)\"> in the head." },
  "GOV-007": { mode: "input", does: "Adds basic Organization structured data (JSON-LD) with the name and address you enter.",
    howTo: "An SEO plugin (for example Yoast or Rank Math on WordPress) can publish Organization schema from its settings; hosted builders usually add it from the business info settings." },
  "GOV-008": { mode: "manual", does: "Not changed automatically: the page's content is built by script in the browser, so the served HTML is an empty shell.",
    howTo: "Serve the content in the HTML itself: turn on server-side rendering or static pre-rendering in the site's framework, or move key pages to a builder that serves HTML." },
};

// What an HTML audit cannot see, stated on every result the way a SITREP states
// its scope, so a clean result is never read as a clean site.
export const NOT_CHECKED = [
  "Security headers (HSTS, Content-Security-Policy, framing, nosniff, referrer and permissions policies)",
  "Cookies and their Secure, HttpOnly and SameSite flags",
  "HTTP to HTTPS redirects and whether the final page is served over HTTPS",
  "Email authentication (SPF, DMARC, MTA-STS) and certificate issuance (CAA)",
  "Availability and response time",
  "robots.txt, sitemap, llms.txt and security.txt",
  "Login pages and exposed admin or database paths",
];

export type Choices = {
  lang?: string;
  title?: string;
  alts?: Array<string | null>;
  fixZoom?: boolean;
  fieldLabels?: Array<string | null>;
  linkLabels?: Array<string | null>;
  privacyUrl?: string;
  termsUrl?: string;
  upgradeForms?: boolean;
  upgradeMixed?: boolean;
  sri?: Record<string, string>;
  description?: string;
  canonical?: string;
  org?: { name: string; url?: string };
};

export type Change = { rule_id: string; summary: string };

export const LANGUAGES: Array<[string, string]> = [
  ["en", "English"], ["en-US", "English (United States)"], ["en-GB", "English (United Kingdom)"],
  ["es", "Spanish"], ["es-US", "Spanish (United States)"], ["fr", "French"], ["de", "German"],
  ["it", "Italian"], ["pt", "Portuguese"], ["pt-BR", "Portuguese (Brazil)"], ["nl", "Dutch"],
  ["zh", "Chinese"], ["ja", "Japanese"], ["ko", "Korean"], ["ar", "Arabic"], ["hi", "Hindi"],
  ["ru", "Russian"], ["pl", "Polish"], ["vi", "Vietnamese"], ["tl", "Tagalog"],
];

const LANG_RE = /^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$/;

export function escapeAttr(v: string): string {
  return v.replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}
function escapeText(v: string): string {
  return v.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}
function clean(v: unknown, max: number): string {
  return typeof v === "string" ? v.replace(/[\u0000-\u001f]/g, " ").trim().slice(0, max) : "";
}
export function safeUrl(v: unknown): string | null {
  const s = clean(v, 2000);
  if (!s) return null;
  try {
    const u = new URL(s);
    return u.protocol === "https:" || u.protocol === "http:" ? u.toString() : null;
  } catch { return null; }
}

/** Adds ` name="value"` just before a start tag closes. */
function withAttr(tag: string, name: string, value: string): string {
  return tag.replace(/\s*(\/?)>$/, (_m, slash) => ` ${name}="${escapeAttr(value)}"${slash ? " /" : ""}>`);
}

/** Literal replace of the first occurrence. String.replace would read "$&" in user text as a pattern. */
function replaceOnce(s: string, find: string, repl: string): string {
  const at = s.indexOf(find);
  return at === -1 ? s : s.slice(0, at) + repl + s.slice(at + find.length);
}

/** Replaces each target tag, in document order, starting after the previous one. */
function replaceInOrder(html: string, targets: string[], fn: (tag: string, i: number) => string | null): { html: string; count: number } {
  let out = "", cursor = 0, count = 0;
  targets.forEach((t, i) => {
    const at = html.indexOf(t, cursor);
    if (at === -1) return;
    const next = fn(t, i);
    out += html.slice(cursor, at) + (next ?? t);
    cursor = at + t.length;
    if (next !== null && next !== t) count += 1;
  });
  return { html: out + html.slice(cursor), count };
}

function insertIntoHead(html: string, snippet: string): string {
  const close = html.search(/<\/head>/i);
  if (close !== -1) return html.slice(0, close) + snippet + "\n" + html.slice(close);
  const open = html.match(/<head\b[^>]*>/i);
  if (open && open.index !== undefined) return html.slice(0, open.index + open[0].length) + "\n" + snippet + html.slice(open.index + open[0].length);
  const htmlTag = html.match(/<html\b[^>]*>/i);
  if (htmlTag && htmlTag.index !== undefined) return html.slice(0, htmlTag.index + htmlTag[0].length) + "\n<head>" + snippet + "</head>" + html.slice(htmlTag.index + htmlTag[0].length);
  return snippet + "\n" + html;
}

function insertFooterLink(html: string, href: string, text: string): string {
  const link = `<a href="${escapeAttr(href)}">${escapeText(text)}</a>`;
  const footer = html.search(/<\/footer>/i);
  if (footer !== -1) return html.slice(0, footer) + ` ${link}\n` + html.slice(footer);
  const body = html.search(/<\/body>/i);
  if (body !== -1) return html.slice(0, body) + `<p>${link}</p>\n` + html.slice(body);
  return html + `\n<p>${link}</p>`;
}

/**
 * Applies only what was chosen. Anything empty, invalid or not applicable is
 * skipped, never guessed.
 *
 * Order matters. Alt text, field names and link names are matched to the
 * operator's answers by position in the ORIGINAL audit, so each of those steps
 * edits only its own kind of tag and leaves every other target's text intact:
 * links first (only the <a> open tag changes, so an <img> inside keeps its
 * exact text), then fields, then images. The http -> https upgrades are not
 * positional, so they re-read the page as it now stands.
 */
export function applyFixes(html: string, pageUrl: string | null | undefined, choices: Choices): { html: string; changes: Change[] } {
  const before = audit(html, pageUrl);
  const has = (id: string) => before.findings.some((f) => f.rule_id === id);
  const changes: Change[] = [];
  const plural = (n: number, one: string, many = one + "s") => `${n} ${n === 1 ? one : many}`;
  let out = html;

  if (has("A11Y-001") && choices.lang && LANG_RE.test(choices.lang)) {
    const tag = out.match(/<html\b[^>]*>/i)?.[0];
    if (tag && !attr(tag, "lang")) {
      out = replaceOnce(out, tag, withAttr(tag, "lang", choices.lang));
      changes.push({ rule_id: "A11Y-001", summary: `Declared the page language as ${choices.lang}.` });
    }
  }

  const title = clean(choices.title, 120);
  if (has("A11Y-002") && title) {
    const existing = out.match(/<title\b[^>]*>[\s\S]*?<\/title>/i);
    const el = `<title>${escapeText(title)}</title>`;
    out = existing ? replaceOnce(out, existing[0], el) : insertIntoHead(out, el);
    changes.push({ rule_id: "A11Y-002", summary: `Set the page title to "${title}".` });
  }

  if (has("A11Y-004") && choices.fixZoom) {
    const vp = out.match(/<meta\b[^>]*name\s*=\s*["']viewport["'][^>]*>/i)?.[0];
    const content = vp ? attr(vp, "content") : null;
    if (vp && content !== null) {
      const kept = content.split(",").map((p) => p.trim()).filter((p) => {
        if (!p) return false;
        if (/^user-scalable\s*=\s*(no|0)$/i.test(p)) return false;
        const m = p.match(/^maximum-scale\s*=\s*([\d.]+)$/i);
        return !(m && parseFloat(m[1]) < 2);
      });
      const next = vp.replace(/(\scontent\s*=\s*)("[^"]*"|'[^']*'|[^\s>]+)/i, (_m, lead) => `${lead}"${escapeAttr(kept.join(", "))}"`);
      out = replaceOnce(out, vp, next);
      changes.push({ rule_id: "A11Y-004", summary: "Allowed pinch zoom in the viewport tag." });
    }
  }

  if (has("A11Y-007") && choices.linkLabels) {
    const r = replaceInOrder(out, before.targets.empty_links, (tag, i) => {
      const v = clean(choices.linkLabels![i], 120);
      if (!v) return null;
      return tag.replace(/^<a\b[^>]*>/i, (open) => withAttr(open, "aria-label", v));
    });
    out = r.html;
    if (r.count) changes.push({ rule_id: "A11Y-007", summary: `Named ${plural(r.count, "link")} for screen readers.` });
  }

  if (has("A11Y-006") && choices.fieldLabels) {
    const r = replaceInOrder(out, before.targets.form_labels, (tag, i) => {
      const v = clean(choices.fieldLabels![i], 120);
      return v ? withAttr(tag, "aria-label", v) : null;
    });
    out = r.html;
    if (r.count) changes.push({ rule_id: "A11Y-006", summary: `Named ${plural(r.count, "form field")} for screen readers.` });
  }

  if (has("A11Y-003") && choices.alts) {
    let decorative = 0;
    const r = replaceInOrder(out, before.targets.img_alt, (tag, i) => {
      const v = choices.alts![i];
      if (typeof v !== "string") return null;
      const text = clean(v, 250);
      if (!text) decorative += 1;
      return withAttr(tag, "alt", text);
    });
    out = r.html;
    if (r.count) changes.push({ rule_id: "A11Y-003", summary: `Added alt text to ${plural(r.count, "image")}${decorative ? `, ${decorative} of them marked decorative (empty alt)` : ""}.` });
  }

  const privacyUrl = safeUrl(choices.privacyUrl);
  if (has("PRIV-001") && privacyUrl) {
    out = insertFooterLink(out, privacyUrl, "Privacy Policy");
    changes.push({ rule_id: "PRIV-001", summary: "Linked the privacy policy from the footer." });
  }
  const termsUrl = safeUrl(choices.termsUrl);
  if (has("PRIV-004") && termsUrl) {
    out = insertFooterLink(out, termsUrl, "Terms of Service");
    changes.push({ rule_id: "PRIV-004", summary: "Linked the terms of service from the footer." });
  }

  if (has("PRIV-003") && choices.upgradeForms) {
    const r = replaceInOrder(out, audit(out, pageUrl).targets.forms, (tag) => {
      const action = attr(tag, "action");
      return action && /^http:\/\//i.test(action) ? tag.replace(/(\saction\s*=\s*["']?)http:\/\//i, "$1https://") : null;
    });
    out = r.html;
    if (r.count) changes.push({ rule_id: "PRIV-003", summary: `Moved ${plural(r.count, "form")} from http:// to https://.` });
  }

  if (has("SEC-010") && choices.upgradeMixed) {
    const r = replaceInOrder(out, audit(out, pageUrl).targets.mixed, (tag) => tag.replace(/(\s(?:src|href|data)\s*=\s*["']?)http:\/\//i, "$1https://"));
    out = r.html;
    if (r.count) changes.push({ rule_id: "SEC-010", summary: `Moved ${plural(r.count, "resource")} from http:// to https://.` });
  }

  if (has("SEC-014") && choices.sri && Object.keys(choices.sri).length) {
    let n = 0;
    out = out.replace(/<script\b[^>]*>/gi, (tag) => {
      const src = attr(tag, "src");
      const integrity = src ? choices.sri![src] : undefined;
      if (!integrity || !SRI_RE.test(integrity) || attr(tag, "integrity")) return tag;
      n += 1;
      let t = withAttr(tag, "integrity", integrity);
      if (!/\scrossorigin(\s|=|>|\/)/i.test(t)) t = withAttr(t, "crossorigin", "anonymous");
      return t;
    });
    if (n) changes.push({ rule_id: "SEC-014", summary: `Pinned ${plural(n, "outside script")} with an integrity hash.` });
  }

  const description = clean(choices.description, 320);
  if (has("GOV-003") && description) {
    out = insertIntoHead(out, `<meta name="description" content="${escapeAttr(description)}">`);
    changes.push({ rule_id: "GOV-003", summary: "Added a meta description." });
  }

  const canonical = safeUrl(choices.canonical);
  if (has("GOV-005") && canonical) {
    out = insertIntoHead(out, `<link rel="canonical" href="${escapeAttr(canonical)}">`);
    changes.push({ rule_id: "GOV-005", summary: `Added a canonical link to ${canonical}.` });
  }

  const orgName = clean(choices.org?.name, 160);
  if (has("GOV-007") && orgName) {
    const data: Record<string, string> = { "@context": "https://schema.org", "@type": "Organization", name: orgName };
    const url = safeUrl(choices.org?.url);
    if (url) data.url = url;
    // "</" inside the JSON would close the script element early.
    const json = JSON.stringify(data).replace(/</g, "\\u003c");
    out = insertIntoHead(out, `<script type="application/ld+json">${json}</script>`);
    changes.push({ rule_id: "GOV-007", summary: "Added Organization structured data." });
  }

  return { html: out, changes };
}

export const SRI_RE = /^sha(256|384|512)-[A-Za-z0-9+/]+={0,2}$/;

export type SriCandidate = { src: string; url: string; host: string; versioned: boolean };

/**
 * The outside scripts SEC-014 counts against the page: third-party, not a tag
 * manager or analytics vendor (those change by design), no integrity yet.
 * `versioned` is only a hint for the default tick; the operator decides.
 */
export function sriCandidates(html: string, pageUrl?: string | null): SriCandidate[] {
  const ctx = contextFor(pageUrl);
  const seen = new Set<string>();
  const out: SriCandidate[] = [];
  for (const s of extractScripts(html, ctx.finalUrl, ctx.host)) {
    if (s.hasIntegrity || isMutableByDesign(s.host) || seen.has(s.src)) continue;
    seen.add(s.src);
    let url: string;
    try { url = new URL(s.src, ctx.finalUrl).toString(); } catch { continue; }
    out.push({ src: s.src, url, host: s.host, versioned: looksVersioned(s.src) });
  }
  return out;
}

/**
 * Whether the edge function may fetch this address to hash it. The address is
 * pasted HTML, so it is attacker-controlled as far as the server is concerned:
 * https only, a public DNS name (no IP literals, no localhost, no internal
 * suffixes), default port. Redirects are refused at fetch time as well.
 */
export function isFetchableScriptUrl(raw: string): boolean {
  let u: URL;
  try { u = new URL(raw); } catch { return false; }
  if (u.protocol !== "https:" || u.username || u.password || (u.port && u.port !== "443")) return false;
  const h = u.hostname.toLowerCase().replace(/\.$/, "");
  if (!h.includes(".") || h.startsWith("[") || /^[\d.]+$/.test(h) || /^0x/i.test(h)) return false;
  if (/(^|\.)(localhost|local|internal|intranet|lan|home|corp|invalid|test|example|onion|arpa)$/.test(h)) return false;
  return true;
}

/** The integrity value for a script's bytes: sha384, the browser default in SRI examples. */
export async function sriFor(bytes: Uint8Array): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-384", bytes));
  let bin = "";
  for (const b of digest) bin += String.fromCharCode(b);
  return "sha384-" + btoa(bin);
}

/** A script pinned to a version is safe to hash; one that changes at its address is not. */
export function looksVersioned(src: string): boolean {
  return /@\d+\.\d+|[/.-]v?\d+\.\d+\.\d+|[?&](ver|v|version)=\d/i.test(src);
}
