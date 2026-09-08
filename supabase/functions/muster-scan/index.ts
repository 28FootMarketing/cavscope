import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

// MUSTER scan engine, phase 1: HTTP-native checks.
// Reads nothing from the muster schema directly; every DB call goes through public.muster_engine_* RPCs
// (service_role only). Each finding cites the evidence rows it was derived from, by key -> evidence id.
//
// Invocation (Authorization: Bearer <anon key>, x-muster-secret: <vault muster_cron_secret>):
//   { "scan_id": 123 }            run one queued scan
//   { "mode": "due", "limit": 3 } claim due websites and stale queued scans, run each

const ENGINE_VERSION = "http-native-1.0.1";
const TIMEOUT_MS = 15000;
const MAX_BODY_BYTES = 1_000_000;
const EXCERPT_BYTES = 4096;
const DEGRADED_MS = 3000;
const HSTS_MIN_AGE = 15552000;
const MAX_HOPS = 6;
// Identifies MUSTER to every site it touches. The URL has to resolve: the
// previous +https://muster.28footsystems.com/scanner 404s, because no
// /scanner page was ever built and that host is not even routed by
// middleware.js. muster.partners is the product's home and explains what
// MUSTER is, which is what an operator seeing this in their logs wants.
const UA = "Mozilla/5.0 (compatible; MUSTER-Scanner/1.0; +https://muster.partners)";

const TRACKER_HOSTS: Array<[RegExp, string]> = [
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
const AI_BOTS = ["GPTBot", "ChatGPT-User", "OAI-SearchBot", "ClaudeBot", "Claude-Web", "anthropic-ai", "PerplexityBot", "Google-Extended", "CCBot", "Bytespider", "Applebot-Extended", "Amazonbot", "meta-externalagent"];

type Evidence = {
  key: string; kind: string; url: string; http_status: number | null; content_type: string | null;
  response_ms: number | null; headers: Record<string, string> | null; excerpt: string | null;
  byte_length: number | null; sha256: string | null;
};
type Severity = "critical" | "high" | "medium" | "low" | "info";
type Finding = {
  rule_id: string; severity: Severity; title: string; detail: string; page_url: string;
  location: string | null; confidence: "high" | "medium" | "low"; evidence_keys: string[];
};
type Fetched = {
  ok: boolean; status: number | null; headers: Record<string, string>; setCookies: string[];
  body: string; bytes: number; ms: number; error: string | null; contentType: string | null; url: string;
};

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

async function sha256Hex(text: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function fetchOnce(url: string, method: "GET" | "HEAD" = "GET"): Promise<Fetched> {
  const started = Date.now();
  const out: Fetched = { ok: false, status: null, headers: {}, setCookies: [], body: "", bytes: 0, ms: 0, error: null, contentType: null, url };
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  try {
    const res = await fetch(url, { method, redirect: "manual", signal: ctrl.signal, headers: { "user-agent": UA, accept: "text/html,application/xhtml+xml,*/*;q=0.8" } });
    out.status = res.status;
    out.ok = res.ok;
    res.headers.forEach((v, k) => { if (k.toLowerCase() !== "set-cookie") out.headers[k.toLowerCase()] = v; });
    // deno-lint-ignore no-explicit-any
    const gsc = (res.headers as any).getSetCookie ? (res.headers as any).getSetCookie() as string[] : [];
    out.setCookies = gsc ?? [];
    out.contentType = res.headers.get("content-type");
    if (method === "GET" && res.body) {
      const reader = res.body.getReader();
      const chunks: Uint8Array[] = [];
      let total = 0;
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        if (value) {
          total += value.byteLength;
          if (total <= MAX_BODY_BYTES) chunks.push(value);
          else { chunks.push(value.subarray(0, Math.max(0, MAX_BODY_BYTES - (total - value.byteLength)))); await reader.cancel(); break; }
        }
      }
      out.bytes = total;
      const merged = new Uint8Array(chunks.reduce((n, c) => n + c.byteLength, 0));
      let off = 0; for (const c of chunks) { merged.set(c, off); off += c.byteLength; }
      out.body = new TextDecoder("utf-8", { fatal: false }).decode(merged);
    } else {
      await res.body?.cancel();
    }
  } catch (e) {
    out.error = String(e).slice(0, 300);
  } finally {
    clearTimeout(timer);
    out.ms = Date.now() - started;
  }
  return out;
}

async function followChain(startUrl: string) {
  const hops: Array<{ url: string; status: number | null; location: string | null; ms: number; error: string | null }> = [];
  let url = startUrl;
  let last: Fetched | null = null;
  for (let i = 0; i < MAX_HOPS; i++) {
    const r = await fetchOnce(url, "GET");
    const loc = r.headers["location"] ?? null;
    hops.push({ url, status: r.status, location: loc, ms: r.ms, error: r.error });
    last = r;
    if (r.status && r.status >= 300 && r.status < 400 && loc) {
      try { url = new URL(loc, url).toString(); } catch { break; }
      continue;
    }
    break;
  }
  return { final: last!, finalUrl: url, hops };
}

function headerList(h: Record<string, string>) {
  return Object.keys(h).sort().map((k) => `${k}: ${h[k]}`).join("\n");
}

function attr(tag: string, name: string): string | null {
  const m = tag.match(new RegExp(`\\s${name}\\s*=\\s*("([^"]*)"|'([^']*)'|([^\\s>]+))`, "i"));
  if (!m) return null;
  return (m[2] ?? m[3] ?? m[4] ?? "").trim();
}
function hasAttr(tag: string, name: string) { return new RegExp(`\\s${name}(\\s|=|>|/)`, "i").test(tag); }
function stripTags(s: string) { return s.replace(/<[^>]*>/g, "").replace(/\s+/g, " ").trim(); }
function hostOf(u: string): string | null { try { return new URL(u).hostname.toLowerCase(); } catch { return null; } }

async function runScan(job: { scan_id: number; website_id: number; target_url: string; website_name: string }) {
  const evidence: Evidence[] = [];
  const findings: Finding[] = [];
  const target = job.target_url;
  const ev = async (e: Omit<Evidence, "sha256"> & { sha256?: string | null }, rawForHash?: string) => {
    evidence.push({ ...e, sha256: e.sha256 ?? (rawForHash != null ? await sha256Hex(rawForHash) : null) });
  };
  const add = (f: Omit<Finding, "page_url"> & { page_url?: string }) => findings.push({ page_url: target, ...f });

  // 1. Primary fetch with redirect chain
  const chain = await followChain(target);
  const primary = chain.final;
  const finalUrl = chain.finalUrl;
  await ev({ key: "chain", kind: "redirect_chain", url: target, http_status: chain.hops[0]?.status ?? null, content_type: null,
    response_ms: chain.hops.reduce((n, h) => n + h.ms, 0), headers: null, excerpt: JSON.stringify(chain.hops, null, 2), byte_length: null }, JSON.stringify(chain.hops));
  await ev({ key: "primary", kind: "http_response", url: finalUrl, http_status: primary.status, content_type: primary.contentType,
    response_ms: primary.ms, headers: primary.headers, excerpt: primary.body.slice(0, EXCERPT_BYTES), byte_length: primary.bytes }, primary.body || (primary.error ?? ""));
  await ev({ key: "headers", kind: "header_set", url: finalUrl, http_status: primary.status, content_type: null, response_ms: null,
    headers: primary.headers, excerpt: headerList(primary.headers) + (primary.setCookies.length ? "\nset-cookie: " + primary.setCookies.join("\nset-cookie: ") : ""), byte_length: null }, headerList(primary.headers));

  const reachable = primary.status !== null && primary.status < 400 && !primary.error;
  if (!reachable) {
    add({ rule_id: "AVAIL-001", severity: "critical", title: "Site unreachable or returning an error",
      detail: primary.error ? `Request failed: ${primary.error}` : `Homepage returned HTTP ${primary.status} after ${chain.hops.length} hop(s).`,
      location: "homepage", confidence: "high", evidence_keys: ["primary", "chain"] });
  }
  if (reachable && primary.ms > DEGRADED_MS) {
    add({ rule_id: "AVAIL-002", severity: "medium", title: "Slow first response", detail: `First byte of the final page took ${primary.ms} ms (threshold ${DEGRADED_MS} ms).`,
      location: "homepage", confidence: "high", evidence_keys: ["primary"] });
  }

  const isHttps = finalUrl.startsWith("https://");
  if (reachable && !isHttps) {
    add({ rule_id: "SEC-013", severity: "critical", title: "Final page served over HTTP", detail: `After redirects the homepage resolved to ${finalUrl}, which is not HTTPS.`,
      location: "homepage", confidence: "high", evidence_keys: ["chain", "primary"] });
  }

  // 2. HTTP -> HTTPS probe
  const host = hostOf(finalUrl) ?? hostOf(target);
  if (host) {
    const probe = await fetchOnce(`http://${host}/`, "HEAD");
    await ev({ key: "http_probe", kind: "http_probe", url: `http://${host}/`, http_status: probe.status, content_type: null, response_ms: probe.ms,
      headers: probe.headers, excerpt: probe.error ?? `HTTP ${probe.status}${probe.headers["location"] ? " -> " + probe.headers["location"] : ""}`, byte_length: null },
      probe.error ?? `${probe.status}|${probe.headers["location"] ?? ""}`);
    if (!probe.error && probe.status !== null) {
      const loc = probe.headers["location"] ?? "";
      const redirectsToHttps = probe.status >= 300 && probe.status < 400 && /^https:\/\//i.test(loc);
      if (!redirectsToHttps) {
        add({ rule_id: "SEC-001", severity: "high", title: "HTTP does not redirect to HTTPS",
          detail: `http://${host}/ returned HTTP ${probe.status}${loc ? ` with Location ${loc}` : " with no redirect to https://"}.`,
          location: `http://${host}/`, confidence: "high", evidence_keys: ["http_probe"] });
      }
    }
  }

  // 3. Security headers (only meaningful when reachable over HTTPS)
  const h = primary.headers;
  if (reachable) {
    if (isHttps) {
      const hsts = h["strict-transport-security"];
      if (!hsts) {
        add({ rule_id: "SEC-002", severity: "medium", title: "Missing Strict-Transport-Security header", detail: "No Strict-Transport-Security header on the HTTPS response.", location: "response headers", confidence: "high", evidence_keys: ["headers"] });
      } else {
        const m = hsts.match(/max-age\s*=\s*(\d+)/i);
        const age = m ? parseInt(m[1], 10) : 0;
        if (age < HSTS_MIN_AGE) add({ rule_id: "SEC-003", severity: "low", title: "Weak HSTS max-age", detail: `Strict-Transport-Security is "${hsts}" (max-age ${age}s, minimum recommended ${HSTS_MIN_AGE}s).`, location: "response headers", confidence: "high", evidence_keys: ["headers"] });
      }
    }
    const csp = h["content-security-policy"];
    if (!csp) add({ rule_id: "SEC-004", severity: "medium", title: "Missing Content-Security-Policy", detail: "No Content-Security-Policy header was returned with the homepage.", location: "response headers", confidence: "high", evidence_keys: ["headers"] });
    const xfo = h["x-frame-options"];
    if (!xfo && !(csp && /frame-ancestors/i.test(csp))) add({ rule_id: "SEC-005", severity: "medium", title: "Clickjacking protection missing", detail: "Neither X-Frame-Options nor a CSP frame-ancestors directive is present.", location: "response headers", confidence: "high", evidence_keys: ["headers"] });
    if (!/nosniff/i.test(h["x-content-type-options"] ?? "")) add({ rule_id: "SEC-006", severity: "low", title: "Missing X-Content-Type-Options", detail: "X-Content-Type-Options: nosniff is not set.", location: "response headers", confidence: "high", evidence_keys: ["headers"] });
    if (!h["referrer-policy"]) add({ rule_id: "SEC-007", severity: "low", title: "Missing Referrer-Policy", detail: "No Referrer-Policy header is set.", location: "response headers", confidence: "high", evidence_keys: ["headers"] });
    if (!h["permissions-policy"]) add({ rule_id: "SEC-008", severity: "low", title: "Missing Permissions-Policy", detail: "No Permissions-Policy header is set.", location: "response headers", confidence: "high", evidence_keys: ["headers"] });
    const leak = ["server", "x-powered-by", "x-aspnet-version", "x-generator"].filter((k) => h[k] && /\d/.test(h[k]));
    if (leak.length) add({ rule_id: "SEC-009", severity: "low", title: "Server software version disclosed", detail: leak.map((k) => `${k}: ${h[k]}`).join("; "), location: "response headers", confidence: "high", evidence_keys: ["headers"] });
    const badCookies = primary.setCookies.filter((c) => !/;\s*secure/i.test(c) || !/;\s*httponly/i.test(c) || !/;\s*samesite=/i.test(c));
    if (badCookies.length) {
      add({ rule_id: "SEC-011", severity: "medium", title: "Cookie set without protective flags",
        detail: badCookies.map((c) => c.split(";")[0].split("=")[0] + ": missing " + [!/;\s*secure/i.test(c) && "Secure", !/;\s*httponly/i.test(c) && "HttpOnly", !/;\s*samesite=/i.test(c) && "SameSite"].filter(Boolean).join(", ")).join(" | ").slice(0, 1500),
        location: "set-cookie", confidence: "high", evidence_keys: ["headers"] });
    }
  }

  // 4. HTML content rules
  const html = primary.body || "";
  const isHtml = reachable && /text\/html|application\/xhtml/i.test(primary.contentType ?? "") && html.length > 0;
  if (isHtml) {
    const snippets: string[] = [];
    // Client-rendered apps ship almost no markup; content rules then carry low confidence until the browser engine runs.
    const visibleText = stripTags(html.replace(/<(script|style|noscript)\b[\s\S]*?<\/\1>/gi, ""));
    const clientRendered = visibleText.length < 200 && /<script\b/i.test(html);
    const csrNote = clientRendered ? " The page appears to render client-side; the HTTP engine only sees the initial HTML. Confirm with the browser engine." : "";
    const csrConf = (c: "high" | "medium" | "low") => (clientRendered ? "low" : c);
    const snip = async (key: string, label: string, tags: string[]) => {
      const text = `${label}\n\n` + tags.slice(0, 20).map((t) => t.slice(0, 300)).join("\n");
      await ev({ key, kind: "html_excerpt", url: finalUrl, http_status: primary.status, content_type: primary.contentType, response_ms: null, headers: null, excerpt: text.slice(0, 8000), byte_length: text.length }, text);
      snippets.push(key);
    };

    const htmlTag = html.match(/<html\b[^>]*>/i)?.[0] ?? "";
    if (!htmlTag || !attr(htmlTag, "lang")) {
      add({ rule_id: "A11Y-001", severity: "medium", title: "Page language not declared", detail: htmlTag ? `The html element is "${htmlTag.slice(0, 120)}" with no lang attribute.` : "No html element with a lang attribute was found.", location: "<html>", confidence: "high", evidence_keys: ["primary"] });
    }
    const title = html.match(/<title\b[^>]*>([\s\S]*?)<\/title>/i);
    if (!title || !stripTags(title[1])) add({ rule_id: "A11Y-002", severity: "medium", title: "Page title missing or empty", detail: "No non-empty <title> element was found in the document head.", location: "<title>", confidence: "high", evidence_keys: ["primary"] });

    const imgs = html.match(/<img\b[^>]*>/gi) ?? [];
    const noAlt = imgs.filter((t) => !hasAttr(t, "alt") && !/\srole\s*=\s*["']?presentation/i.test(t) && !/\saria-hidden\s*=\s*["']?true/i.test(t));
    if (noAlt.length) {
      await snip("img_alt", `${noAlt.length} of ${imgs.length} img elements have no alt attribute:`, noAlt);
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
      await snip("form_labels", `${unlabeled.length} form fields with no label, aria-label, or aria-labelledby:`, unlabeled);
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
      await snip("empty_links", `${emptyLinks.length} links with no discernible text:`, emptyLinks);
      add({ rule_id: "A11Y-007", severity: "medium", title: "Links with no discernible text", detail: `${emptyLinks.length} link(s) have no text, aria-label, or image alt text.` + csrNote, location: "<a>", confidence: csrConf("medium"), evidence_keys: ["empty_links", "primary"] });
    }

    // Privacy policy link
    const anchors = [...html.matchAll(/<a\b[^>]*>([\s\S]*?)<\/a>/gi)];
    const privacy = anchors.some((m) => /privacy/i.test(attr(m[0].match(/^<a\b[^>]*>/i)?.[0] ?? "", "href") ?? "") || /privacy/i.test(stripTags(m[1])));
    if (!privacy) add({ rule_id: "PRIV-001", severity: clientRendered ? "low" : "medium", title: "No privacy policy link found", detail: `Scanned ${anchors.length} links on the homepage; none contained "privacy" in its text or href.` + csrNote, location: "homepage links", confidence: csrConf("medium"), evidence_keys: ["primary"] });

    // Scripts, trackers, mixed content
    const scriptSrcs = [...html.matchAll(/<script\b[^>]*\ssrc\s*=\s*["']([^"']+)["']/gi)].map((m) => m[1]);
    const external = scriptSrcs.map((s) => { try { return new URL(s, finalUrl); } catch { return null; } }).filter((u): u is URL => !!u && u.hostname.toLowerCase() !== host);
    const extHosts = [...new Set(external.map((u) => u.hostname.toLowerCase()))];
    if (extHosts.length) {
      await snip("scripts", `External script hosts (${extHosts.length}):`, extHosts.map((hn) => hn + "  <- " + external.filter((u) => u.hostname.toLowerCase() === hn).map((u) => u.pathname).slice(0, 3).join(", ")));
      add({ rule_id: "TP-001", severity: "info", title: "External script inventory", detail: `${external.length} external script(s) from ${extHosts.length} host(s): ${extHosts.slice(0, 15).join(", ")}${extHosts.length > 15 ? ", ..." : ""}.`, location: "<script src>", confidence: "high", evidence_keys: ["scripts"] });
      const trackers = [...new Set(TRACKER_HOSTS.filter(([re]) => external.some((u) => re.test(u.href)) || re.test(html)).map(([, n]) => n))];
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
        await snip("mixed", `${mixed.length} insecure (http://) resource references on an HTTPS page:`, mixed);
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
      await snip("forms", `${badForms.length} forms posting over http:// or to an external host:`, badForms);
      add({ rule_id: "PRIV-003", severity: "medium", title: "Form submits to an insecure or external endpoint", detail: `${badForms.length} form(s) post to http:// or to a domain other than ${host}.`, location: "<form action>", confidence: "medium", evidence_keys: ["forms"] });
    }
    // Governance / AIO
    if (!/<meta\b[^>]*name\s*=\s*["']description["']/i.test(html)) add({ rule_id: "GOV-003", severity: "info", title: "Meta description missing", detail: "No <meta name=\"description\"> on the homepage.", location: "<head>", confidence: "high", evidence_keys: ["primary"] });
    if (!/<link\b[^>]*rel\s*=\s*["']canonical["']/i.test(html)) add({ rule_id: "GOV-005", severity: "info", title: "Canonical link missing", detail: "No <link rel=\"canonical\"> on the homepage.", location: "<head>", confidence: "high", evidence_keys: ["primary"] });
    void snippets;
  }

  // 5. robots.txt, sitemap, security.txt
  if (reachable && host) {
    const origin = `${isHttps ? "https" : "http"}://${host}`;
    const robots = await fetchOnce(`${origin}/robots.txt`, "GET");
    const robotsOk = robots.status === 200 && !/text\/html/i.test(robots.contentType ?? "") && robots.body.length > 0;
    await ev({ key: "robots", kind: "robots_txt", url: `${origin}/robots.txt`, http_status: robots.status, content_type: robots.contentType, response_ms: robots.ms, headers: null, excerpt: robots.body.slice(0, 8000), byte_length: robots.bytes }, robots.body || String(robots.status));
    let sitemapUrl = `${origin}/sitemap.xml`;
    if (!robotsOk) {
      add({ rule_id: "GOV-001", severity: "low", title: "robots.txt missing", detail: `GET /robots.txt returned HTTP ${robots.status ?? "error"}${/text\/html/i.test(robots.contentType ?? "") ? " (an HTML page, not a robots file)" : ""}.`, location: "/robots.txt", confidence: "high", evidence_keys: ["robots"] });
    } else {
      const sm = robots.body.match(/^\s*sitemap\s*:\s*(\S+)/im);
      if (sm) sitemapUrl = sm[1];
      // AI crawler directives
      const blocks = robots.body.split(/\n(?=\s*user-agent\s*:)/i);
      const blocked: string[] = []; const addressed: string[] = [];
      for (const bot of AI_BOTS) {
        const blk = blocks.find((b) => new RegExp(`user-agent\\s*:\\s*${bot.replace(/[-]/g, "\\-")}\\s*$`, "im").test(b));
        if (!blk) continue;
        addressed.push(bot);
        if (/^\s*disallow\s*:\s*\/\s*$/im.test(blk)) blocked.push(bot);
      }
      add({ rule_id: "GOV-004", severity: "info", title: "AI crawler directives",
        detail: addressed.length ? `Addressed: ${addressed.join(", ")}. Fully blocked: ${blocked.length ? blocked.join(", ") : "none"}.` : "robots.txt has no directives for known AI crawlers (GPTBot, ClaudeBot, PerplexityBot, Google-Extended, CCBot). The decision is unaddressed.",
        location: "/robots.txt", confidence: "high", evidence_keys: ["robots"] });
    }
    const sitemap = await fetchOnce(sitemapUrl, "GET");
    const sitemapOk = sitemap.status === 200 && /<(urlset|sitemapindex)\b/i.test(sitemap.body.slice(0, 4000));
    await ev({ key: "sitemap", kind: "sitemap", url: sitemapUrl, http_status: sitemap.status, content_type: sitemap.contentType, response_ms: sitemap.ms, headers: null, excerpt: sitemap.body.slice(0, 2000), byte_length: sitemap.bytes }, sitemap.body.slice(0, 20000) || String(sitemap.status));
    if (!sitemapOk) add({ rule_id: "GOV-002", severity: "low", title: "XML sitemap not found", detail: `${sitemapUrl} returned HTTP ${sitemap.status ?? "error"}${sitemap.status === 200 ? " but the body is not a sitemap" : ""}.`, location: sitemapUrl, confidence: "high", evidence_keys: ["sitemap"] });

    const sec = await fetchOnce(`${origin}/.well-known/security.txt`, "GET");
    const secOk = sec.status === 200 && /^\s*contact\s*:/im.test(sec.body);
    await ev({ key: "security_txt", kind: "security_txt", url: `${origin}/.well-known/security.txt`, http_status: sec.status, content_type: sec.contentType, response_ms: sec.ms, headers: null, excerpt: sec.body.slice(0, 4000), byte_length: sec.bytes }, sec.body || String(sec.status));
    if (!secOk) add({ rule_id: "SEC-012", severity: "low", title: "No security.txt disclosure policy", detail: `/.well-known/security.txt returned HTTP ${sec.status ?? "error"}${sec.status === 200 ? " without a Contact field" : ""}.`, location: "/.well-known/security.txt", confidence: "high", evidence_keys: ["security_txt"] });
  }

  const scanMeta = { final_url: finalUrl, http_status: primary.status, response_ms: primary.ms, engine_version: ENGINE_VERSION };
  const { data: ingest, error: ingestErr } = await db.rpc("muster_engine_ingest", { p_scan_id: job.scan_id, p_scan: scanMeta, p_evidence: evidence, p_findings: findings });
  if (ingestErr) throw new Error("ingest failed: " + ingestErr.message);
  const { data: sitrep, error: sitrepErr } = await db.rpc("muster_engine_sitrep", { p_scan_id: job.scan_id });
  if (sitrepErr) throw new Error("sitrep failed: " + sitrepErr.message);
  return { scan_id: job.scan_id, website: job.website_name, final_url: finalUrl, findings: findings.length, evidence: evidence.length, ingest, sitrep };
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  const { data: secret } = await db.rpc("muster_engine_secret");
  const provided = req.headers.get("x-muster-secret") ?? "";
  if (!secret || provided !== secret) return json({ error: "unauthorized" }, 401);

  let body: { scan_id?: number; mode?: string; limit?: number } = {};
  try { body = await req.json(); } catch { /* empty body means due mode */ }

  const { data: jobs, error } = await db.rpc("muster_engine_claim", {
    p_scan_id: body.scan_id ?? null,
    p_limit: Math.max(1, Math.min(body.limit ?? 3, 5)),
  });
  if (error) return json({ error: error.message }, 500);
  const results: unknown[] = [];
  for (const raw of (jobs ?? []) as Array<Record<string, unknown>>) {
    const job = raw as { scan_id: number; website_id: number; target_url: string; website_name: string };
    try {
      results.push(await runScan(job));
    } catch (e) {
      const msg = String(e).slice(0, 1500);
      await db.rpc("muster_engine_fail", { p_scan_id: job.scan_id, p_error: msg });
      results.push({ scan_id: job.scan_id, error: msg });
    }
  }
  return json({ engine: ENGINE_VERSION, claimed: (jobs ?? []).length, results });
});
