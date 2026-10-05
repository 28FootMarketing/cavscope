// Host and tracker knowledge for TP-002 and PRIV-006.

// A short list of multi-label public suffixes. Not the whole Public Suffix List: a miss here makes a
// third-party host look first-party (or the reverse) for a site on an exotic suffix, which is why the
// report states the registrable domain it used.
const MULTI_SUFFIXES = new Set([
  "co.uk", "org.uk", "ac.uk", "gov.uk", "com.au", "net.au", "org.au", "co.nz", "co.jp", "co.in", "co.za",
  "com.br", "com.mx", "com.cn", "com.tr", "k12.pa.us", "k12.ny.us", "k12.va.us", "k12.nj.us", "k12.oh.us",
  "k12.tx.us", "k12.ca.us", "k12.fl.us", "pvt.k12.ma.us", "ci.us", "co.us", "state.pa.us", "state.ny.us",
]);

export function registrableDomain(host) {
  const h = String(host || "").toLowerCase().replace(/\.$/, "");
  if (!h || /^\d+\.\d+\.\d+\.\d+$/.test(h) || h.includes(":")) return h;
  const labels = h.split(".");
  if (labels.length <= 2) return h;
  for (let take = Math.min(4, labels.length - 1); take >= 2; take--) {
    if (MULTI_SUFFIXES.has(labels.slice(-take).join("."))) return labels.slice(-(take + 1)).join(".");
  }
  return labels.slice(-2).join(".");
}

export function isFirstParty(requestHost, siteHost) {
  return registrableDomain(requestHost) === registrableDomain(siteHost);
}

// Advertising and analytics cookies by name. Conservative: exact names and well-known prefixes only.
const TRACKER_COOKIE = [
  /^_ga(_.+)?$/, /^_gid$/, /^_gat(_.+)?$/, /^_gcl_.+$/, /^_fbp$/, /^_fbc$/, /^fr$/, /^_uet.+$/, /^_clck$/, /^_clsk$/,
  /^_hj.+$/, /^ajs_(user|anonymous)_id$/, /^__utm[a-z]$/, /^_pin_unauth$/, /^_scid$/, /^_ttp$/, /^_tt_.+$/,
  /^hubspotutk$/, /^__hs.+$/, /^_li_.+$/, /^li_sugr$/, /^IDE$/, /^test_cookie$/, /^NID$/, /^_rdt_uuid$/, /^mp_.+_mixpanel$/,
];
export function isTrackerCookie(name) { return TRACKER_COOKIE.some((re) => re.test(name)); }

// Hosts whose only job is advertising or analytics. A request to one before any interaction is what
// PRIV-006 reports.
const TRACKER_HOSTS = [
  "google-analytics.com", "analytics.google.com", "googletagmanager.com", "doubleclick.net", "googleadservices.com",
  "googlesyndication.com", "facebook.net", "facebook.com", "connect.facebook.net", "fbcdn.net", "clarity.ms", "hotjar.com",
  "hotjar.io", "segment.io", "segment.com", "cdn.segment.com", "mixpanel.com", "amplitude.com", "fullstory.com",
  "tiktok.com", "analytics.tiktok.com", "snap.licdn.com", "px.ads.linkedin.com", "ads.linkedin.com", "adsrvr.org",
  "criteo.com", "taboola.com", "outbrain.com", "hs-analytics.net", "hsadspixel.net", "pinterest.com", "ct.pinterest.com",
  "bat.bing.com", "quantserve.com", "scorecardresearch.com", "twitter.com", "ads-twitter.com", "static.ads-twitter.com",
];
export function isTrackerHost(host) {
  const h = String(host || "").toLowerCase();
  return TRACKER_HOSTS.some((t) => h === t || h.endsWith("." + t));
}

// NS provider mapping for OPS-002.
const NS_PROVIDERS = [
  [/registrar-servers\.com$/i, "Namecheap"], [/(^|\.)ns\.cloudflare\.com$/i, "Cloudflare"],
  [/vercel-dns\.com$/i, "Vercel DNS"], [/awsdns-/i, "Amazon Route 53"], [/domaincontrol\.com$/i, "GoDaddy"],
  [/wixdns\.net$/i, "Wix"], [/(^|\.)google(domains)?\.com$/i, "Google Domains / Cloud DNS"],
  [/azure-dns\./i, "Azure DNS"], [/dnsmadeeasy\.com$/i, "DNS Made Easy"], [/squarespacedns\.com$/i, "Squarespace"],
];
export function dnsProvider(nsHosts) {
  const found = new Set();
  for (const ns of nsHosts || []) for (const [re, name] of NS_PROVIDERS) if (re.test(ns)) found.add(name);
  return [...found];
}
