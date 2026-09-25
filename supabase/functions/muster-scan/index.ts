import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import {
  dmarcCandidates, evaluateEmailAuth, mailDomain,
  spfRecords, spfLookupTerms, evaluateSpfLookups, SPF_MAX_LOOKUPS,
} from "./email-auth.ts";
import { caaNames, evaluateCaa, evaluateDnssec, evaluateMtaSts, evaluateSubresourceIntegrity, extractScripts } from "./hardening.ts";
import { detectClientRendered, stripTags } from "./html.ts";
import { responseRejectedByClient } from "./availability.ts";
import {
  ADMIN_PROBES, MAX_LOGIN_PAGES, evaluateAdminProbes, evaluateLoginPage, findLoginLinks,
  cookieName, frameable, hasPasswordField, isSameSite, passwordForms, probeHit, type ProbeResult,
} from "./login.ts";
import { EXPOSURE_PROBES, evaluateExposure, exposureHit, type ExposureProbeResult } from "./exposure.ts";
import { PROBE_ORIGIN, evaluateCors } from "./cors.ts";
import { evaluateCspQuality } from "./csp.ts";

// CavScope scan engine, phase 1: HTTP-native checks.
// Reads nothing from the muster schema directly; every DB call goes through public.muster_engine_* RPCs
// (service_role only). Each finding cites the evidence rows it was derived from, by key -> evidence id.
//
// Invocation (Authorization: Bearer <anon key>, x-muster-secret: <vault muster_cron_secret>):
//   { "scan_id": 123 }            run one queued scan
//   { "mode": "due", "limit": 3 } claim due websites and stale queued scans, run each

// 1.3.0, not 1.2.1, and not 1.2.0 as this branch originally said. Client-
// rendered pages now downgrade content findings as they were always meant to
// (issue #93), and origin-file probes follow the target's port (issue #94):
// both change what the engine reports, not just how.
//
// The bump is to 1.3.0 because 1.2.0 was taken while this branch was open, by
// SEC-014/SEC-015/EMAIL-008 (#103) -- a different rule set entirely. Landing
// this as 1.2.0 too would have put two materially different engines behind one
// version string, which is the exact thing the version exists to prevent: a
// finding's severity is only comparable across scans on the same version.
//
// Migration 20260916210100 holds those three rules inactive until a scan is
// confirmed reporting 1.2.0. That precondition is now unreachable and should be
// read as "1.3.0 or later"; see that migration's header before activating.
//
// 1.4.0 adds AVAIL-003: a homepage that answers 401, 403 or 429 is now reported
// as "could not be assessed" rather than as an outage. Rule output changed, so
// the minor moves -- and the value to move it from is the one on main, not the
// one this branch started at.
//
// 1.5.0 adds EMAIL-009: SPF is now walked and its DNS-querying terms counted
// against RFC 7208's limit of 10. This is the first rule that resolves names it
// discovers rather than names it was given, so it is bounded three ways -- a
// visited set against include cycles, a node cap against a deep tree, and an
// early stop once the count is past the limit and the answer cannot change.
//
// 1.6.0 adds AVAIL-004: a response the HTTP client received and refused to parse
// is no longer reported as an outage. hpsd.k12.pa.us answered `invalid HTTP
// header parsed` over HTTPS while serving 200 to a lenient client and to this
// engine's own plain-HTTP probe in the same scan, and AVAIL-001 called that
// "Visitors cannot load the site."
//
// 1.7.0 adds AUTH-001..005: the login surface, read from outside. The engine
// now follows up to three same-site "Sign in" links from the homepage and GETs
// five default admin paths, judging only pages whose served HTML contains a
// password field. It still signs in to nothing and submits nothing; see
// login.ts for what it deliberately leaves alone.
//
// 1.7.1 stops AUTH-003 reporting wordpress_test_cookie. It holds the constant
// "WP Cookie check" and never becomes a session, but it was AUTH-003's first
// live firing (hanoverymca.org, scan 86), which would have put a medium finding
// on every WordPress login page for a cookie that carries nothing. A patch
// rather than a minor: one rule stops emitting one false case, and no rule is
// added. It still moves, because rule output changed.
//
// 1.8.0 adds three rules from supabase/migrations/
// 20260923190000_muster_086_hardening_gap_rules_inactive.sql -- SEC-016
// (sensitive file/path exposure, judged by content signature the same way
// AUTH-004/005 judge an admin console), SEC-017 (CORS that reflects an
// untrusted Origin with Access-Control-Allow-Credentials: true, probed with a
// sentinel Origin on the .invalid TLD so any trust of it is definitionally not
// a real allowlist entry), and SEC-018 (a CSP present but weakened by
// unsafe-inline/unsafe-eval/a bare wildcard script source, which SEC-004
// cannot see because it only checks presence).
//
// Do NOT activate the migration's rows the moment this deploys. Same
// precondition as every rule before it: wait for a scan to report
// http-native-1.8.0 or later in muster.scans.engine_version, then activate in
// a separate migration.
//
// SEC-019 (TRACE/TRACK enabled) is in that migration too, inactive, with NO
// activation path from this engine. fetch() throws `TypeError: Method is
// forbidden` for TRACE, TRACK and CONNECT -- confirmed against Deno 2.9.7,
// and it is the WHATWG Fetch spec's own forbidden-method list, not a Deno
// quirk, so no runtime with a spec-compliant fetch() can send one. The one
// way around it is a raw TCP/TLS socket instead of fetch(), and this file's
// own DNS section above already establishes why that is not available here:
// DNS goes over DoH "because the edge runtime does not expose a resolver, and
// [...] an HTTPS call is subject to the same egress rules as everything else
// here" -- i.e. fetch() is the only egress this runtime grants, not a Deno
// CLI default that merely went unused. (Headers are a different story: Deno's
// fetch does NOT restrict Origin/Host/Cookie the way a browser would -- there
// is no page origin to protect in a server runtime -- which is what makes
// SEC-017's Origin-reflection probe above possible at all.) Until someone
// confirms Deno.connect works inside the deployed muster-scan function
// specifically -- not just in the Deno CLI -- SEC-019 has no engine and
// should be treated as retired, not merely unscheduled.
//
// 1.9.0 adds AUTH-006 (a login page served without Cache-Control: no-store,
// judged on the login page alone -- unlike AUTH-001..003 it has no homepage
// baseline, because an ordinary page is meant to be cached and a login page
// never is) and SEC-020 (no DS record at the registrable domain, so a
// resolver cannot detect a forged DNS answer anywhere under it). SEC-020
// reuses the apex SEC-015/CAA already computes and needed a new scan_evidence
// kind, `dns_ds` -- added by supabase/migrations/
// 20260923200000_muster_087_dns_ds_evidence_kind.sql in the same change that
// emits it, per the CAA/dns_caa precedent (muster_061). That filename's
// timestamp is a placeholder until apply_migration assigns the real one --
// see supabase/migrations/README.md before this is actually applied.
const ENGINE_VERSION = "http-native-1.9.0";
const TIMEOUT_MS = 15000;
const MAX_BODY_BYTES = 1_000_000;
const EXCERPT_BYTES = 4096;
const DEGRADED_MS = 3000;
const HSTS_MIN_AGE = 15552000;
const MAX_HOPS = 6;
// Identifies CavScope to every site it touches. The URL has to resolve: the
// previous +https://muster.28footsystems.com/scanner 404s, because no /scanner
// page was ever built. muster.partners is kept alive and now serves
// CavScope-branded content -- see CLAUDE.md's brand section and
// docs/BRAND-CUTOVER.md -- so it still explains what CavScope is, which is
// what an operator seeing this in their logs wants. Point this at
// https://cavscope.28footsystems.com once that domain actually resolves in
// production; not before, for the same reason the old /scanner path was
// dropped -- a UA string should never link to a 404.
const UA = "Mozilla/5.0 (compatible; CavScope-Scanner/1.0; +https://muster.partners)";

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

async function fetchOnce(url: string, method: "GET" | "HEAD" = "GET", timeoutMs = TIMEOUT_MS, extraHeaders: Record<string, string> = {}): Promise<Fetched> {
  const started = Date.now();
  const out: Fetched = { ok: false, status: null, headers: {}, setCookies: [], body: "", bytes: 0, ms: 0, error: null, contentType: null, url };
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    // extraHeaders exists for SEC-017's CORS probe (an Origin header the
    // caller controls). Deno's fetch does not enforce the browser
    // forbidden-header-name list -- confirmed empirically against Deno
    // 2.9.7: setting origin/host/cookie here reaches the network layer the
    // same as any other header, because there is no page origin to protect
    // in a server runtime. Only HTTP *methods* are restricted (see
    // ENGINE_VERSION's 1.8.0 note on why that kills SEC-019).
    const res = await fetch(url, { method, redirect: "manual", signal: ctrl.signal, headers: { "user-agent": UA, accept: "text/html,application/xhtml+xml,*/*;q=0.8", ...extraHeaders } });
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

async function followChain(startUrl: string, maxHops = MAX_HOPS, timeoutMs = TIMEOUT_MS) {
  const hops: Array<{ url: string; status: number | null; location: string | null; ms: number; error: string | null }> = [];
  let url = startUrl;
  let last: Fetched | null = null;
  for (let i = 0; i < maxHops; i++) {
    const r = await fetchOnce(url, "GET", timeoutMs);
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
function hostOf(u: string): string | null { try { return new URL(u).hostname.toLowerCase(); } catch { return null; } }

// DNS over HTTPS. The scanner has never resolved a name -- every other check is
// fetch() against the site -- so this is the one place it asks the DNS system a
// question. DoH rather than Deno.resolveDns because the edge runtime does not
// expose a resolver, and because an HTTPS call is subject to the same egress
// rules as everything else here.
//
// Google is primary and Cloudflare is the fallback: a single resolver being
// unreachable must not become "this domain has no SPF", which would be a
// high-severity finding manufactured from an outage.
const DOH_ENDPOINTS = [
  "https://dns.google/resolve",
  "https://cloudflare-dns.com/dns-query",
];

async function resolveTxt(name: string): Promise<{ txt: string[]; failed: boolean }> {
  for (const base of DOH_ENDPOINTS) {
    try {
      const ctrl = new AbortController();
      const t = setTimeout(() => ctrl.abort(), 5000);
      const res = await fetch(`${base}?name=${encodeURIComponent(name)}&type=TXT`, {
        headers: { accept: "application/dns-json" }, signal: ctrl.signal,
      });
      clearTimeout(t);
      if (!res.ok) continue;
      const body = await res.json();
      // NXDOMAIN (3) is a real answer -- the name does not exist -- and must be
      // reported as absence, not as a resolver failure.
      if (body?.Status !== 0 && body?.Status !== 3) continue;
      const txt = (body?.Answer ?? [])
        .filter((a: { type?: number }) => a?.type === 16)
        .map((a: { data?: string }) => String(a?.data ?? "").replace(/^"|"$/g, "").replace(/"\s+"/g, ""));
      return { txt, failed: false };
    } catch { /* try the next resolver */ }
  }
  return { txt: [], failed: true };
}

async function resolveMx(name: string): Promise<string[]> {
  try {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), 5000);
    const res = await fetch(`${DOH_ENDPOINTS[0]}?name=${encodeURIComponent(name)}&type=MX`, {
      headers: { accept: "application/dns-json" }, signal: ctrl.signal,
    });
    clearTimeout(t);
    if (!res.ok) return [];
    const body = await res.json();
    return (body?.Answer ?? [])
      .filter((a: { type?: number }) => a?.type === 15)
      .map((a: { data?: string }) => String(a?.data ?? "").trim());
  } catch { return []; }
}

// CAA is DNS type 257. Same failover as resolveTxt and for the same reason: a
// single resolver being unreachable must not become "no CAA is published",
// which is a finding about certificate issuance manufactured from an outage.
async function resolveCaa(name: string): Promise<{ records: string[]; failed: boolean }> {
  for (const base of DOH_ENDPOINTS) {
    try {
      const ctrl = new AbortController();
      const t = setTimeout(() => ctrl.abort(), 5000);
      const res = await fetch(`${base}?name=${encodeURIComponent(name)}&type=CAA`, {
        headers: { accept: "application/dns-json" }, signal: ctrl.signal,
      });
      clearTimeout(t);
      if (!res.ok) continue;
      const body = await res.json();
      // NXDOMAIN is an answer -- the name does not exist, so it has no CAA.
      if (body?.Status !== 0 && body?.Status !== 3) continue;
      const records = (body?.Answer ?? [])
        .filter((a: { type?: number }) => a?.type === 257)
        .map((a: { data?: string }) => String(a?.data ?? "").trim())
        .filter(Boolean);
      return { records, failed: false };
    } catch { /* try the next resolver */ }
  }
  return { records: [], failed: true };
}

// DS is DNS type 43. Same failover as resolveCaa, for the same reason: a
// single resolver being unreachable must not become "no DS record", which is
// a DNSSEC finding manufactured from an outage rather than a real absence.
async function resolveDs(name: string): Promise<{ records: string[]; failed: boolean }> {
  for (const base of DOH_ENDPOINTS) {
    try {
      const ctrl = new AbortController();
      const t = setTimeout(() => ctrl.abort(), 5000);
      const res = await fetch(`${base}?name=${encodeURIComponent(name)}&type=DS`, {
        headers: { accept: "application/dns-json" }, signal: ctrl.signal,
      });
      clearTimeout(t);
      if (!res.ok) continue;
      const body = await res.json();
      if (body?.Status !== 0 && body?.Status !== 3) continue;
      const records = (body?.Answer ?? [])
        .filter((a: { type?: number }) => a?.type === 43)
        .map((a: { data?: string }) => String(a?.data ?? "").trim())
        .filter(Boolean);
      return { records, failed: false };
    } catch { /* try the next resolver */ }
  }
  return { records: [], failed: true };
}

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
  // 401, 403 and 429 mean the server answered and declined us. That is a
  // different fact from "nobody can reach this", and reporting it as an outage
  // is a claim about a page the engine never read -- the same failure as issue
  // #93, pointed the other way. A 404 homepage is genuinely broken and a 5xx is
  // genuinely an outage, so both stay on AVAIL-001.
  //
  // One request cannot distinguish bot protection from a 403 served to
  // everyone, so AVAIL-003 does not guess: it reports what happened and its
  // remediation covers both readings. It keeps critical severity on purpose --
  // see migration 20260917071020 (muster_065) -- because a lighter weight would
  // score an unreadable site 99/100 green.
  const refused = !primary.error && (primary.status === 401 || primary.status === 403 || primary.status === 429);
  // A response that arrived and failed parsing is a third thing again: the
  // server answered, so "unreachable" is false, and it did not decline us, so
  // "refused" is false too. See availability.ts for why the match is positive
  // evidence that a server answered rather than a guess.
  const unparsable = !refused && responseRejectedByClient(primary.error);
  if (refused) {
    add({ rule_id: "AVAIL-003", severity: "critical", title: "Site could not be assessed: the scanner was refused",
      detail: `The homepage returned HTTP ${primary.status} after ${chain.hops.length} hop(s). The server answered, so it is running, but it declined this request -- commonly a WAF, CDN bot filter or rate limiter rejecting the CavScope-Scanner user agent. No markup, headers or cookies were read, so every HTTP-derived rule produced nothing for this site and its score reflects an unassessed target rather than a clean one. DNS-derived checks are independent of the web server and still ran.`,
      location: "homepage", confidence: "high", evidence_keys: ["primary", "chain"] });
  } else if (unparsable) {
    add({ rule_id: "AVAIL-004", severity: "critical", title: "Site could not be assessed: the response was not valid HTTP",
      detail: `The server answered, but the response could not be parsed as HTTP and the request was abandoned: ${primary.error}. Response bytes were received and then rejected during parsing, which is not an outage -- the host is running, and a lenient client such as a browser may load the page normally. It is also not nothing: strict HTTP clients, monitoring agents, proxies, security scanners and API integrations built on the same parsers fail the same way, and the fault is in what the origin emits rather than in who asks. No markup, headers or cookies were read, so every HTTP-derived rule produced nothing for this site and its score reflects an unassessed target rather than a clean one. DNS-derived checks are independent of the web server and still ran.`,
      location: "homepage", confidence: "high", evidence_keys: ["primary", "chain"] });
  } else if (!reachable) {
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

  // 2. HTTP -> HTTPS probe.
  // This one drops the port on purpose: SEC-001 asks whether plain HTTP on port
  // 80 redirects to HTTPS, which is a question about port 80 specifically. Do
  // not "fix" it to match the origin below (issue #94) -- that changes what the
  // rule measures. When the probe cannot connect it raises nothing, because a
  // probe that never reached a server is not evidence of a missing redirect.
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
    // SEC-018 reuses the same "headers" evidence SEC-004 already recorded and
    // returns nothing when csp is absent -- that case belongs to SEC-004
    // alone, and scoring both would be the same double-count AUTH-*/SEC-005/
    // SEC-011 already guard against in login.ts.
    for (const f of evaluateCspQuality({ csp: csp ?? null, evidenceKey: "headers" })) add(f);
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

  // 3b. CORS (SEC-017): one extra HEAD to the homepage carrying an Origin no
  // real site could have allowlisted -- cors.ts's PROBE_ORIGIN sits on the
  // .invalid TLD, reserved by RFC 2606 to never resolve and never be
  // assigned, so any server that trusts it is trusting a domain that cannot
  // exist. HEAD rather than GET: the check only reads response headers, and
  // this is a second request against a site the homepage fetch already read.
  // See cors.ts for why only exact reflection combined with
  // Access-Control-Allow-Credentials: true is flagged -- a bare wildcard or
  // reflection without credentials is not exploitable and is not reported.
  if (reachable) {
    const corsProbe = await fetchOnce(finalUrl, "HEAD", TIMEOUT_MS, { origin: PROBE_ORIGIN });
    const allowOrigin = corsProbe.headers["access-control-allow-origin"] ?? null;
    const allowCredentials = (corsProbe.headers["access-control-allow-credentials"] ?? "").trim().toLowerCase() === "true";
    await ev({ key: "cors_probe", kind: "http_probe", url: finalUrl, http_status: corsProbe.status, content_type: null, response_ms: corsProbe.ms,
      headers: corsProbe.headers,
      excerpt: `Origin sent: ${PROBE_ORIGIN}\nAccess-Control-Allow-Origin: ${allowOrigin ?? "(absent)"}\nAccess-Control-Allow-Credentials: ${allowCredentials}`,
      byte_length: null }, `${allowOrigin ?? ""}|${allowCredentials}`);
    for (const f of evaluateCors({ result: { probedOrigin: PROBE_ORIGIN, allowOrigin, allowCredentials }, evidenceKey: "cors_probe" })) add(f);
  }

  // 4. HTML content rules
  const html = primary.body || "";
  const isHtml = reachable && /text\/html|application\/xhtml/i.test(primary.contentType ?? "") && html.length > 0;
  if (isHtml) {
    const snippets: string[] = [];
    // Client-rendered apps ship almost no markup; content rules then carry low confidence until the browser engine runs.
    const clientRendered = detectClientRendered(html);
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
    // Must be the full origin, port included: `host` is hostname-only, so a
    // target on a non-default port had robots.txt, the sitemap and security.txt
    // fetched from the default port -- judging a different server, or none.
    // See issue #94. `host` stays hostname-only for the same-site comparisons
    // in TP-001 and PRIV-003, where a port would be wrong.
    const origin = new URL(finalUrl).origin;
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

  // 5b. The login surface (AUTH-*), read the way an anonymous visitor reads it.
  // Plain GETs only: nothing is submitted, no credential is sent, and a page
  // counts as a login page only if its served HTML contains a password field.
  // Every request goes out at once, with a shorter timeout and hop limit than
  // the homepage gets, so a site where every path hangs costs this section
  // about 3 x 8 s of wall clock rather than 8 x 90 s.
  //
  // The homepage is never assessed here even when it holds a login form: its
  // transport, framing and cookies are already SEC-013, PRIV-003, SEC-005 and
  // SEC-011, and one defect must not be scored twice.
  if (reachable && host) {
    const LOGIN_TIMEOUT_MS = 8000;
    const LOGIN_HOPS = 3;
    const origin = new URL(finalUrl).origin;
    const dropHash = (u: string) => u.replace(/#.*$/, "");
    const homeKey = dropHash(finalUrl);
    const onSite = (u: string) => { const hn = hostOf(u); return hn !== null && isSameSite(hn, host); };
    const links = isHtml ? findLoginLinks(html, finalUrl, host) : { onSite: [] as string[], offSite: [] as string[] };

    const [linked, probed] = await Promise.all([
      Promise.all(links.onSite.map((u) => followChain(u, LOGIN_HOPS, LOGIN_TIMEOUT_MS))),
      Promise.all(ADMIN_PROBES.map((p) => followChain(origin + p.path, LOGIN_HOPS, LOGIN_TIMEOUT_MS))),
    ]);

    const probeResults: ProbeResult[] = probed.map((c, i) => ({
      probe: ADMIN_PROBES[i],
      finalUrl: onSite(c.finalUrl) ? dropHash(c.finalUrl) : null,
      status: c.final.status,
      body: c.final.body,
    }));

    const pages: Array<{ url: string; res: Fetched; via: string }> = [];
    const notes: string[] = [];
    const consider = (c: { final: Fetched; finalUrl: string }, via: string) => {
      const url = dropHash(c.finalUrl);
      if (!onSite(url)) { notes.push(`${via}: left the site for ${url}; not assessed, it is not this site's page`); return; }
      if (c.final.error || c.final.status === null || c.final.status >= 400) { notes.push(`${via}: ${c.final.error ?? `HTTP ${c.final.status}`}`); return; }
      if (url === homeKey) { notes.push(`${via}: is the homepage, already judged by the SEC-* rules`); return; }
      if (!/text\/html|application\/xhtml/i.test(c.final.contentType ?? "") || !hasPasswordField(c.final.body)) {
        notes.push(`${via}: no password field in the served HTML; a form rendered by JavaScript, or a single sign-on button, is not visible to the HTTP engine`);
        return;
      }
      if (pages.some((pg) => pg.url === url)) { notes.push(`${via}: same page as one already assessed`); return; }
      if (pages.length >= MAX_LOGIN_PAGES) { notes.push(`${via}: not assessed, ${MAX_LOGIN_PAGES}-page limit reached`); return; }
      pages.push({ url, res: c.final, via });
    };
    // What the SEC-* rules already reported on the homepage, so AUTH-* only
    // raises what is worse on the login page. Mirrors SEC-005 and SEC-011's own
    // conditions rather than reading their findings back, which would couple
    // this section to the order the rules happen to run in.
    const homepage = {
      https: isHttps,
      frameProtected: !frameable(primary.headers),
      flaggedCookies: primary.setCookies
        .filter((c) => !/;\s*secure/i.test(c) || !/;\s*httponly/i.test(c) || !/;\s*samesite=/i.test(c))
        .map(cookieName),
    };
    linked.forEach((c, i) => consider(c, `link ${links.onSite[i]}`));
    probed.forEach((c, i) => { if (probeHit(probeResults[i])) consider(c, `default path ${ADMIN_PROBES[i].path}`); });

    const discovery = [
      `homepage has a password field: ${isHtml && hasPasswordField(html) ? "yes (judged by SEC-013, PRIV-003, SEC-005, SEC-011)" : "no"}`,
      `sign-in links followed: ${links.onSite.length ? links.onSite.join(", ") : "none found"}`,
      `off-site sign-in links, not assessed: ${links.offSite.length ? links.offSite.join(", ") : "none"}`,
      "default admin paths:",
      ...probeResults.map((r) => `  ${r.probe.path} -> ${r.status ?? "error"}${r.finalUrl === null ? " (left the site)" : ""}${probeHit(r) ? ` MATCHED ${r.probe.product}` : ""}`),
      `login pages assessed: ${pages.length ? pages.map((pg) => `${pg.url} (via ${pg.via})`).join(", ") : "none"}`,
      ...(notes.length ? ["notes:", ...notes.map((n) => "  " + n)] : []),
    ].join("\n");
    // Written whenever this section runs, found or not. AUTH-* is silent on a
    // site with no login page, so a counter cannot prove the code executed;
    // this row can, the same way dns_spf_chain proved EMAIL-009.
    // Kind is http_probe because scan_evidence.kind is a CHECK-constrained
    // list; a new kind would fail ingest and take the whole scan with it.
    await ev({ key: "login_discovery", kind: "http_probe", url: origin + "/", http_status: null, content_type: null, response_ms: null,
      headers: null, excerpt: discovery.slice(0, 8000), byte_length: discovery.length }, discovery);

    for (const [i, pg] of pages.entries()) {
      const key = `login_${i + 1}`;
      const formTags = passwordForms(pg.res.body, pg.url).map((f) => `${f.tag.slice(0, 300)}  -> ${f.action ?? "(unresolvable action)"}`);
      const excerpt = [headerList(pg.res.headers), ...pg.res.setCookies.map((c) => "set-cookie: " + c),
        "", "password forms:", ...(formTags.length ? formTags : ["(password field outside any <form>; submitted by script)"])].join("\n");
      await ev({ key, kind: "http_response", url: pg.url, http_status: pg.res.status, content_type: pg.res.contentType, response_ms: pg.res.ms,
        headers: pg.res.headers, excerpt: excerpt.slice(0, 8000), byte_length: pg.res.bytes }, pg.res.body);
      for (const f of evaluateLoginPage({ url: pg.url, headers: pg.res.headers, setCookies: pg.res.setCookies, html: pg.res.body, evidenceKey: key, homepage })) add(f);
    }
    for (const f of evaluateAdminProbes({ results: probeResults, evidenceKey: "login_discovery" })) add(f);

    // 5c. Sensitive file/path exposure (SEC-016). Same probe discipline as the
    // admin-console probes just above and the same reason: a plain GET,
    // judged on the body matching that path's own content signature, never on
    // status code alone, so a catch-all 404 or SPA shell answering every path
    // with 200 is never accused of leaking its .git directory. Shares this
    // block's origin/onSite/dropHash and timeout/hop budget rather than
    // opening a second reachable-host guard.
    const exposed = await Promise.all(EXPOSURE_PROBES.map((p) => followChain(origin + p.path, LOGIN_HOPS, LOGIN_TIMEOUT_MS)));
    const exposureResults: ExposureProbeResult[] = exposed.map((c, i) => ({
      probe: EXPOSURE_PROBES[i],
      finalUrl: onSite(c.finalUrl) ? dropHash(c.finalUrl) : null,
      status: c.final.status,
      body: c.final.body,
    }));
    const exposureDiscovery = exposureResults
      .map((r) => `  ${r.probe.path} -> ${r.status ?? "error"}${r.finalUrl === null ? " (left the site)" : ""}${exposureHit(r) ? ` MATCHED (${r.probe.label})` : ""}`)
      .join("\n");
    // Written whether or not anything matched, the same reason login_discovery
    // is: these rules are silent on most sites, so a finding count cannot
    // prove the probes ran, but this evidence row can.
    await ev({ key: "exposure_discovery", kind: "http_probe", url: origin + "/", http_status: null, content_type: null, response_ms: null,
      headers: null, excerpt: `sensitive-path probes:\n${exposureDiscovery}`.slice(0, 8000), byte_length: null }, exposureDiscovery);
    for (const f of evaluateExposure({ results: exposureResults, evidenceKey: "exposure_discovery" })) add(f);
  }

  // 6. Email authentication (EMAIL-*). Runs regardless of whether the site
  // responded: a domain that is down can still be spoofed, and the DNS answer
  // is independent of the web server.
  const mailHost = hostOf(finalUrl) ?? hostOf(target);
  if (mailHost) {
    const domain = mailDomain(mailHost);
    const spf = await resolveTxt(domain);

    let dmarc: { name: string; txt: string[] } | null = null;
    let dmarcFailed = false;
    for (const candidate of dmarcCandidates(mailHost)) {
      const r = await resolveTxt(candidate);
      if (r.failed) { dmarcFailed = true; break; }
      if (r.txt.some((t) => /^v=dmarc1(\s*;|$)/i.test(t.trim()))) { dmarc = { name: candidate, txt: r.txt }; break; }
    }

    const mx = await resolveMx(domain);

    await ev({ key: "dns_spf", kind: "dns_txt", url: `dns:${domain}?type=TXT`, http_status: null, content_type: null,
      response_ms: null, headers: null,
      excerpt: spf.failed ? "resolver unavailable" : (spf.txt.join("\n") || "(no TXT records)"),
      byte_length: null }, spf.txt.join("\n"));

    await ev({ key: "dns_dmarc", kind: "dns_txt", url: `dns:_dmarc.${domain}?type=TXT`, http_status: null, content_type: null,
      response_ms: null, headers: null,
      excerpt: dmarcFailed ? "resolver unavailable" : (dmarc ? `${dmarc.name}\n${dmarc.txt.join("\n")}` : `no DMARC at ${dmarcCandidates(mailHost).join(", ")}`),
      byte_length: null }, dmarc ? dmarc.txt.join("\n") : "");

    await ev({ key: "dns_mx", kind: "dns_mx", url: `dns:${domain}?type=MX`, http_status: null, content_type: null,
      response_ms: null, headers: null, excerpt: mx.join("\n") || "(no MX records)", byte_length: null }, mx.join("\n"));

    for (const f of evaluateEmailAuth({
      host: mailHost, spfTxt: spf.txt, dmarc, mx,
      resolverFailed: spf.failed || dmarcFailed,
    })) add(f);

    // EMAIL-009: walk the SPF tree and count DNS-querying terms.
    //
    // This is the only email rule that cannot be answered from one lookup. The
    // count is not in the record -- a three-term record can be over the limit
    // because a vendor's include nests four of its own -- so it only exists by
    // walking, which is exactly why operators cannot see it and it stays broken.
    if (!spf.failed) {
      const MAX_NODES = 24;
      const seen = new Set<string>([domain]);
      const chain: string[] = [domain];
      let count = 0;
      let incomplete = false;

      // Only a single apex record is walkable. Zero is EMAIL-001 and more than
      // one is EMAIL-003; in both cases receivers never get as far as counting,
      // so a lookup total would describe an evaluation that does not happen.
      const apexRecords = spfRecords(spf.txt);
      let frontier: string[] = apexRecords.length === 1 ? [apexRecords[0]] : [];

      while (frontier.length > 0 && count <= SPF_MAX_LOOKUPS) {
        const next: string[] = [];
        for (const record of frontier) {
          for (const term of spfLookupTerms(record)) {
            count++;
            if (!term.target || seen.has(term.target)) continue;
            // Three bounds, each for a different failure: the visited set stops
            // an include cycle, MAX_NODES stops a deep tree turning one scan
            // into hundreds of queries, and the limit check stops work whose
            // answer cannot change -- already over is already over.
            if (seen.size >= MAX_NODES || count > SPF_MAX_LOOKUPS) { incomplete = true; continue; }
            seen.add(term.target);
            const nested = await resolveTxt(term.target);
            if (nested.failed) { incomplete = true; continue; }
            const recs = spfRecords(nested.txt);
            if (recs.length === 1) { chain.push(term.target); next.push(recs[0]); }
            else if (recs.length > 1) { incomplete = true; }
            // Zero records is a void lookup: it cost a query, already counted,
            // and contributes no further terms.
          }
        }
        frontier = next;
      }

      if (apexRecords.length === 1) {
        await ev({ key: "dns_spf_chain", kind: "dns_txt", url: `dns:${domain}?type=TXT&walk=spf`,
          http_status: null, content_type: null, response_ms: null, headers: null,
          excerpt: `${count}${incomplete ? "+" : ""} of ${SPF_MAX_LOOKUPS} DNS lookups\n` +
            `walked: ${chain.join(" -> ")}` + (incomplete ? "\nwalk incomplete: the count is a floor" : ""),
          byte_length: null }, chain.join("\n"));

        for (const f of evaluateSpfLookups({
          host: mailHost, traversal: { count, chain, incomplete },
        })) add(f);
      }
    }

    // SEC-015: CAA, walked the way a certificate authority walks it -- nearest
    // name first, stopping at the registrable domain. dmarcCandidates already
    // encodes the public-suffix stop, so the apex is read off its last entry
    // rather than re-deriving a suffix list here and letting the two drift.
    const apex = (dmarcCandidates(mailHost).at(-1) ?? `_dmarc.${domain}`).replace(/^_dmarc\./, "");
    const caaAnswers: Array<{ name: string; records: string[] }> = [];
    let caaFailed = false;
    for (const name of caaNames(mailHost, apex)) {
      const r = await resolveCaa(name);
      if (r.failed) { caaFailed = true; break; }
      caaAnswers.push({ name, records: r.records });
      // A CA stops at the first name with a CAA set, so this does too.
      if (r.records.length > 0) break;
    }
    await ev({ key: "dns_caa", kind: "dns_caa", url: `dns:${mailHost}?type=CAA`, http_status: null, content_type: null,
      response_ms: null, headers: null,
      excerpt: caaFailed ? "resolver unavailable" : (caaAnswers.map((a) => `${a.name}: ${a.records.join(" | ") || "(none)"}`).join("\n") || "(no names queried)"),
      byte_length: null }, caaAnswers.map((a) => a.records.join("|")).join("\n"));
    for (const f of evaluateCaa({ host: mailHost, answers: caaAnswers, resolverFailed: caaFailed, evidenceKey: "dns_caa" })) add(f);

    // SEC-020: DNSSEC. Checked at the same apex CAA already computed -- see
    // hardening.ts's evaluateDnssec for why the apex, not the scanned host,
    // is where a resolver looks for the delegation signer.
    const ds = await resolveDs(apex);
    await ev({ key: "dns_ds", kind: "dns_ds", url: `dns:${apex}?type=DS`, http_status: null, content_type: null,
      response_ms: null, headers: null,
      excerpt: ds.failed ? "resolver unavailable" : (ds.records.join("\n") || "(no DS records)"),
      byte_length: null }, ds.records.join("\n"));
    for (const f of evaluateDnssec({ apex, records: ds.records, resolverFailed: ds.failed, evidenceKey: "dns_ds" })) add(f);

    // EMAIL-008: MTA-STS. The policy file is only fetched when the TXT record
    // claims one exists, so a domain with no record costs one lookup and no
    // request to a host that will not answer.
    const stsTxt = await resolveTxt(`_mta-sts.${domain}`);
    let stsPolicy: string | null = null;
    let stsPolicyStatus: number | null = null;
    if (!stsTxt.failed && stsTxt.txt.some((t) => /^v=STSv1\s*;/i.test(t.trim()))) {
      const pol = await fetchOnce(`https://mta-sts.${domain}/.well-known/mta-sts.txt`, "GET");
      stsPolicyStatus = pol.status;
      if (pol.status === 200 && /version\s*:\s*STSv1/i.test(pol.body)) stsPolicy = pol.body;
    }
    await ev({ key: "mta_sts", kind: "dns_txt", url: `dns:_mta-sts.${domain}?type=TXT`, http_status: stsPolicyStatus, content_type: null,
      response_ms: null, headers: null,
      excerpt: stsTxt.failed ? "resolver unavailable" : [
        stsTxt.txt.join("\n") || "(no TXT records)",
        stsPolicyStatus === null ? "" : `policy fetch: HTTP ${stsPolicyStatus}`,
        stsPolicy ? `\n${stsPolicy.slice(0, 1000)}` : "",
      ].filter(Boolean).join("\n"),
      byte_length: null }, stsTxt.txt.join("\n") + (stsPolicy ?? ""));
    for (const f of evaluateMtaSts({
      domain, txt: stsTxt.txt, policy: stsPolicy, mx,
      resolverFailed: stsTxt.failed, evidenceKey: "mta_sts",
    })) add(f);
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
