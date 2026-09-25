// AUTH-001..005: the login surface, read from outside.
//
// MUSTER does not sign in to anything. It holds no client credentials, submits
// no form, and never sends a password -- see docs/SCAN-RULES.md, "No
// authenticated crawl". What it can do is read the login page the way any
// anonymous visitor can, because a login page is public by definition: it is
// the one page every attacker is guaranteed to reach. So these rules ask what a
// login page reveals before anyone types into it: is it encrypted, can it be
// framed, what does it set in the browser, and is an administrative console
// sitting at its default path.
//
// Pure, like email-auth.ts and hardening.ts: index.ts does the fetching and
// hands the responses in; everything here is a function of its arguments.
//
// What it deliberately does NOT do, and why:
//
// - No brute-force or rate-limit probing. Testing whether a login locks out
//   means trying passwords against a real account, which is an attack on the
//   client's users, not a scan of their site.
// - No autocomplete finding. Older scanners flag password fields that allow
//   autofill; current guidance (NIST SP 800-63B, OWASP ASVS) says the opposite
//   -- password managers should be allowed -- so that finding would be advice
//   to make the site worse.
// - No verdict on MFA. Whether a second factor exists is only visible after a
//   correct password, so AUTH-004 says it cannot see it rather than guessing.
// - Nothing off-site. A "Parent Portal" link to a vendor's domain is the
//   vendor's login page, not the client's. It is recorded in evidence and left
//   alone, because scoring a client on a third party's headers is a claim about
//   a system they do not operate.
//
// AUTH-006, added alongside the rest, is judged differently from AUTH-001..003:
// it does NOT compare against a homepage baseline. An ordinary marketing page
// is meant to be cached; a login page never is, regardless of what the
// homepage sends. So it fires on the login page's own Cache-Control alone.

export type Severity = "critical" | "high" | "medium" | "low" | "info";

export type LoginFinding = {
  rule_id: string;
  severity: Severity;
  title: string;
  detail: string;
  page_url: string;
  location: string;
  confidence: "high" | "medium" | "low";
  evidence_keys: string[];
};

/** Most login pages to fetch and evaluate per scan, links and probes together. */
export const MAX_LOGIN_PAGES = 4;
/** Most homepage links followed while looking for a login page. */
export const MAX_LOGIN_LINKS = 3;

// ---------------------------------------------------------------------------
// Scope
// ---------------------------------------------------------------------------

/**
 * Whether `host` belongs to the site being scanned: the same host, or a
 * subdomain of it once a leading `www.` is set aside. `portal.school.org` is
 * the client's when the site is `www.school.org`; `school.powerschool.com` is
 * not, and neither is a lookalike such as `school.org.evil.net`.
 */
export function isSameSite(host: string, siteHost: string): boolean {
  const h = host.toLowerCase().replace(/\.$/, "");
  const base = siteHost.toLowerCase().replace(/\.$/, "").replace(/^www\./, "");
  if (!h || !base) return false;
  return h === base || h.endsWith("." + base);
}

// ---------------------------------------------------------------------------
// Discovery
// ---------------------------------------------------------------------------

const LOGIN_TEXT = /\b(log\s*-?\s*in|sign\s*-?\s*in|signin|login|logon|my\s+account|member\s+area|portal)\b/i;
const LOGIN_PATH = /(^|[\/_.-])(login|log-in|signin|sign-in|logon|auth|account|myaccount|portal|wp-login\.php)([\/_.-]|$)/i;
// A logout link matches LOGIN_TEXT on "log" alone in some markup, and a
// sign-up page is a registration form, not a login.
const NOT_LOGIN = /\b(log\s*-?\s*out|sign\s*-?\s*out|sign\s*-?\s*up|register|registration|forgot|reset)\b/i;

function stripTagsLocal(s: string): string {
  return s.replace(/<[^>]*>/g, " ").replace(/&nbsp;/gi, " ").replace(/\s+/g, " ").trim();
}

function hrefOf(tag: string): string | null {
  const m = tag.match(/\shref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/i);
  if (!m) return null;
  return (m[1] ?? m[2] ?? m[3] ?? "").trim();
}

function withoutHash(u: URL): string {
  const c = new URL(u.toString());
  c.hash = "";
  return c.toString();
}

/**
 * Links on a page that look like the way in to a login. Matched on the link's
 * visible text or its path, never on the query string, which carries tracking
 * parameters that say "login" for unrelated reasons.
 *
 * Returns on-site candidates (to be fetched) and off-site ones (recorded, never
 * fetched), each deduplicated and in document order.
 */
export function findLoginLinks(
  html: string,
  pageUrl: string,
  siteHost: string,
  max = MAX_LOGIN_LINKS,
): { onSite: string[]; offSite: string[] } {
  const onSite: string[] = [];
  const offSite: string[] = [];
  const self = (() => { try { return withoutHash(new URL(pageUrl)); } catch { return pageUrl; } })();
  for (const m of String(html || "").matchAll(/<a\b[^>]*>([\s\S]*?)<\/a>/gi)) {
    const open = m[0].match(/^<a\b[^>]*>/i)?.[0] ?? "";
    const href = hrefOf(open);
    if (!href || href.startsWith("#") || /^(javascript|mailto|tel|data):/i.test(href)) continue;
    let u: URL;
    try { u = new URL(href, pageUrl); } catch { continue; }
    if (u.protocol !== "http:" && u.protocol !== "https:") continue;
    const label = [stripTagsLocal(m[1]), open.match(/\saria-label\s*=\s*["']([^"']*)["']/i)?.[1] ?? "", open.match(/\stitle\s*=\s*["']([^"']*)["']/i)?.[1] ?? ""].join(" ");
    const looksLikeLogin = LOGIN_TEXT.test(label) || LOGIN_PATH.test(u.pathname);
    if (!looksLikeLogin || NOT_LOGIN.test(label) || NOT_LOGIN.test(u.pathname.replace(/[\/_.-]/g, " "))) continue;
    const url = withoutHash(u);
    if (url === self) continue;
    if (isSameSite(u.hostname, siteHost)) {
      if (!onSite.includes(url) && onSite.length < max) onSite.push(url);
    } else if (!offSite.includes(url) && offSite.length < 10) {
      offSite.push(url);
    }
  }
  return { onSite, offSite };
}

// ---------------------------------------------------------------------------
// Reading a login page
// ---------------------------------------------------------------------------

const PASSWORD_INPUT = /<input\b[^>]*\stype\s*=\s*["']?password["'\s/>]/i;

export function hasPasswordField(html: string): boolean {
  return PASSWORD_INPUT.test(String(html || ""));
}

export type PasswordForm = {
  /** The opening <form> tag, for evidence. */
  tag: string;
  /** Where the password goes. An absent or empty action posts to the page itself. */
  action: string | null;
};

/**
 * Every <form> that contains a password field, with its resolved action.
 *
 * A password field outside any <form> is submitted by script, so its
 * destination is not in the markup; it still makes the page a login page, but
 * contributes no action to judge.
 */
export function passwordForms(html: string, pageUrl: string): PasswordForm[] {
  const out: PasswordForm[] = [];
  for (const m of String(html || "").matchAll(/<form\b[^>]*>[\s\S]*?<\/form>/gi)) {
    if (!PASSWORD_INPUT.test(m[0])) continue;
    const tag = m[0].match(/^<form\b[^>]*>/i)?.[0] ?? "<form>";
    const raw = tag.match(/\saction\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/i);
    const rawAction = raw ? (raw[1] ?? raw[2] ?? raw[3] ?? "").trim() : "";
    let action: string | null = null;
    try { action = new URL(rawAction || pageUrl, pageUrl).toString(); } catch { action = null; }
    out.push({ tag, action });
  }
  return out;
}

export function frameable(headers: Record<string, string>): boolean {
  // frame-ancestors is only honoured in a header; a <meta> CSP ignores it by
  // spec, so the body is deliberately not consulted.
  const xfo = headers["x-frame-options"];
  const csp = headers["content-security-policy"];
  return !xfo && !(csp && /frame-ancestors/i.test(csp));
}

/** Anti-forgery tokens that frameworks deliberately expose to script. */
const SCRIPT_READABLE_BY_DESIGN = /csrf|xsrf/i;

/**
 * Cookies a login page sets that carry no identity and never become a
 * session, matched by exact name. Flags on them protect nothing, so asking for
 * them is advice that costs credibility and fixes nothing.
 *
 * Deliberately an exact list, not a pattern, and deliberately short: every
 * entry is a claim that a named product's cookie is inert, and a claim like
 * that is only made after reading what the product puts in it.
 *
 * - wordpress_test_cookie: WordPress sets it on wp-login.php with the constant
 *   value "WP Cookie check" to learn whether the browser accepts cookies. It
 *   was AUTH-003's first live firing (www.hanoverymca.org, scan 86), and the
 *   reason the rule was held back when the rest of the family was activated.
 */
export const INERT_BY_DESIGN = new Set(["wordpress_test_cookie"]);

export function cookieName(setCookie: string): string {
  return setCookie.split(";")[0].split("=")[0].trim() || "(unnamed)";
}

function cookieProblems(setCookies: string[], pageIsHttps: boolean): string[] {
  const out: string[] = [];
  for (const c of setCookies) {
    const name = cookieName(c);
    if (INERT_BY_DESIGN.has(name.toLowerCase())) continue;
    const missing: string[] = [];
    // Secure is only a meaningful ask on HTTPS: on HTTP the page itself is the
    // problem, and AUTH-001 already says so.
    if (pageIsHttps && !/;\s*secure\b/i.test(c)) missing.push("Secure");
    if (!/;\s*httponly\b/i.test(c) && !SCRIPT_READABLE_BY_DESIGN.test(name)) missing.push("HttpOnly");
    if (!/;\s*samesite=/i.test(c)) missing.push("SameSite");
    if (missing.length) out.push(`${name}: missing ${missing.join(", ")}`);
  }
  return out;
}

/**
 * AUTH-001, AUTH-002, AUTH-003 for one fetched page.
 *
 * Returns nothing unless the served HTML contains a password field. That is the
 * only thing that makes a page a login page from outside: a link that said
 * "Sign in" and landed on an SSO button, or on a page that renders its form
 * with JavaScript, is not something the HTTP engine can judge, and a finding
 * about it would be a claim about a form it never saw.
 *
 * The homepage is excluded by the caller, not here: its transport, framing and
 * cookies are already judged by SEC-013, PRIV-003, SEC-005 and SEC-011, and
 * raising AUTH-* for the same response would score one defect twice.
 *
 * For the same reason each rule reports only where the login page is WORSE
 * than the homepage. A site served over HTTP everywhere is one defect, owned by
 * SEC-013 at critical; adding a high per login page would score it again for
 * every page the engine happened to find. Likewise a site with no framing
 * header anywhere is SEC-005's, and a cookie the homepage already set badly is
 * SEC-011's. What remains is what only a login-page check can see: an HTTPS
 * site whose login is not, a framing policy with a hole exactly where it
 * matters, and session cookies that first appear at sign-in.
 */
export type HomepageBaseline = {
  /** The homepage was served over HTTPS. When false, SEC-013 owns transport. */
  https: boolean;
  /** The homepage sent X-Frame-Options or CSP frame-ancestors. When false, SEC-005 owns framing. */
  frameProtected: boolean;
  /** Cookie names SEC-011 already reported on the homepage. */
  flaggedCookies: string[];
};

export function evaluateLoginPage(input: {
  url: string;
  headers: Record<string, string>;
  setCookies: string[];
  html: string;
  evidenceKey: string;
  homepage: HomepageBaseline;
}): LoginFinding[] {
  const { url, headers, setCookies, html, evidenceKey, homepage } = input;
  if (!hasPasswordField(html)) return [];
  const out: LoginFinding[] = [];
  const pageIsHttps = /^https:\/\//i.test(url);
  const forms = passwordForms(html, url);
  const base = { page_url: url, confidence: "high" as const, evidence_keys: [evidenceKey] };

  // On an HTTP page, a same-site HTTP action is that page's own transport and
  // falls under the page-level check below; an HTTP action to another host is
  // not fixed by moving this site to HTTPS, so it always counts.
  const pageHost = (() => { try { return new URL(url).hostname; } catch { return ""; } })();
  const insecureActions = forms.filter((f) => {
    if (!f.action || !/^http:\/\//i.test(f.action)) return false;
    if (pageIsHttps) return true;
    try { return !isSameSite(new URL(f.action).hostname, pageHost); } catch { return false; }
  });
  // An HTTP page on an HTTP site is SEC-013's. An insecure form action is
  // always this rule's: PRIV-003 only reads the homepage's forms.
  const pageRegressed = !pageIsHttps && homepage.https;
  if (pageRegressed || insecureActions.length) {
    const why = pageRegressed
      ? `The homepage is HTTPS, but the login page is served over plain HTTP at ${url}, so the form, and anything a script on it does with what is typed, can be read or altered in transit.`
      : `${insecureActions.length} password form(s) on ${url} submit to plain HTTP: ${insecureActions.map((f) => f.action).join(", ")}. The password leaves the browser unencrypted.`;
    out.push({ ...base, rule_id: "AUTH-001", severity: "high", title: "Login credentials can travel unencrypted",
      detail: why, location: "<form> with a password field" });
  }

  if (homepage.frameProtected && frameable(headers)) {
    out.push({ ...base, rule_id: "AUTH-002", severity: "medium", title: "Login page can be framed by another site",
      detail: `The homepage refuses to be framed, but ${url} returned neither X-Frame-Options nor a Content-Security-Policy frame-ancestors directive. Another site can load this login form inside an invisible frame and trick a visitor into typing into it or clicking through it.`,
      location: "response headers" });
  }

  const already = new Set(homepage.flaggedCookies.map((n) => n.toLowerCase()));
  const bad = cookieProblems(setCookies.filter((c) => !already.has(cookieName(c).toLowerCase())), pageIsHttps);
  if (bad.length) {
    out.push({ ...base, rule_id: "AUTH-003", severity: "medium", title: "Login page sets cookies without protective flags",
      detail: `Before anyone signs in, ${url} sets ${bad.length} cookie(s) without the flags a pre-login session needs: ${bad.join(" | ").slice(0, 1200)}. A session cookie issued before sign-in is often the one that carries the signed-in session afterwards, unless the application issues a new one at sign-in. Anti-forgery tokens (names containing csrf or xsrf) are not asked for HttpOnly, because frameworks expose them to script on purpose, and cookies that carry no identity by design, such as wordpress_test_cookie, are not reported.`,
      location: "set-cookie" });
  }

  // AUTH-006: no-store is the one directive that actually stops a shared
  // cache or a browser's disk cache from retaining the page. no-cache alone
  // still permits storage (it only forces revalidation), so it does not
  // satisfy this check -- a bright line rather than a judgment call about
  // which weaker combination might be good enough. Unlike AUTH-001..003 this
  // does not compare against the homepage: an ordinary page is meant to be
  // cached, a login page never is, so there is no "worse than the homepage"
  // baseline to check against here.
  const cacheControl = headers["cache-control"] ?? "";
  if (!/\bno-store\b/i.test(cacheControl)) {
    out.push({ ...base, rule_id: "AUTH-006", severity: "medium", title: "Login page response is cacheable",
      detail: `${url} does not send Cache-Control: no-store${cacheControl ? ` (sent "${cacheControl}", which does not include no-store)` : " (no Cache-Control header at all)"}. A shared or intermediary cache -- a corporate proxy, a CDN caching by default, or a browser's disk cache on a shared computer -- may retain a copy of this page.`,
      location: "response headers" });
  }
  return out;
}

// ---------------------------------------------------------------------------
// Administrative consoles at their default paths
// ---------------------------------------------------------------------------

export type AdminProbe = {
  path: string;
  product: string;
  kind: "cms" | "database";
  /** True only when the body is recognisably this product's login form. */
  matches: (body: string) => boolean;
};

/**
 * Each probe is a plain GET to a path the product installs by default, and
 * each counts only on a positive signature. A status code alone proves
 * nothing: many sites answer every path with 200 and their homepage, and a
 * finding raised on that would accuse every single-page app of running
 * phpMyAdmin.
 */
export const ADMIN_PROBES: AdminProbe[] = [
  { path: "/wp-login.php", product: "WordPress", kind: "cms",
    matches: (b) => /name\s*=\s*["']?log["'\s>]/i.test(b) && /name\s*=\s*["']?pwd["'\s>]/i.test(b) },
  { path: "/administrator/", product: "Joomla", kind: "cms",
    matches: (b) => /joomla/i.test(b) && hasPasswordField(b) },
  { path: "/user/login", product: "Drupal", kind: "cms",
    matches: (b) => /drupal/i.test(b) && /name\s*=\s*["']?pass["'\s>]/i.test(b) },
  { path: "/phpmyadmin/", product: "phpMyAdmin", kind: "database",
    matches: (b) => /phpmyadmin/i.test(b) && /(pma_username|input_username)/i.test(b) },
  { path: "/adminer.php", product: "Adminer", kind: "database",
    matches: (b) => /adminer/i.test(b) && /auth\[username\]/i.test(b) },
];

export type ProbeResult = {
  probe: AdminProbe;
  /** Final URL after same-site redirects, or null when it left the site. */
  finalUrl: string | null;
  status: number | null;
  body: string;
};

/** Whether a probe landed on its product's login form, on this site. */
export function probeHit(r: ProbeResult): boolean {
  return r.finalUrl !== null && r.status === 200 && r.probe.matches(r.body);
}

/** AUTH-004 (CMS login at its default path) and AUTH-005 (database console). */
export function evaluateAdminProbes(input: {
  results: ProbeResult[];
  evidenceKey: string;
}): LoginFinding[] {
  const out: LoginFinding[] = [];
  for (const r of input.results) {
    if (!probeHit(r)) continue;
    const url = r.finalUrl!;
    if (r.probe.kind === "database") {
      out.push({ rule_id: "AUTH-005", severity: "high", title: "Database administration console is publicly reachable",
        detail: `${r.probe.product}'s login page answers at ${url} to anyone on the internet. It is a direct login to the database behind the site: one weak, reused or leaked password is the whole dataset, and these consoles are among the most scanned paths on the web.`,
        page_url: url, location: r.probe.path, confidence: "high", evidence_keys: [input.evidenceKey] });
    } else {
      out.push({ rule_id: "AUTH-004", severity: "low", title: "CMS administrator login is reachable at its default path",
        detail: `The ${r.probe.product} administrator login answers at ${url}. This is normal for ${r.probe.product} and not a vulnerability on its own; it is where automated password guessing is aimed. MUSTER does not sign in, so it cannot see whether multi-factor authentication or login rate limiting is enforced -- confirm both.`,
        page_url: url, location: r.probe.path, confidence: "high", evidence_keys: [input.evidenceKey] });
    }
  }
  return out;
}
