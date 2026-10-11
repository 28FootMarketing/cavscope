import { rewrite, next } from '@vercel/functions';
import INLINE_SCRIPT_HASHES from './tools/csp/manifest.js';

// Routes each CavScope host to its own static file. vercel.json's declarative
// rewrites cannot branch on the Host header (only real code can), so this uses
// Vercel's Routing Middleware instead.
//
// One host serves the product:
//
//   cavscope.28footsystems.com       path-routed for everything: /, /onboarding,
//                                    /sitrep, /sitrep/sample, /beta, /privacy,
//                                    /signin, /app, /admin, /reset. See the
//                                    block below for why one host can do what
//                                    the old muster.partners / app.muster.partners
//                                    pair needed two hosts for.
//
// Every MUSTER-era host (muster.partners, www., app., onboarding., sitrep.,
// and the *.muster.28footsystems.com originals) answers with a permanent
// redirect to the same page on cavscope.28footsystems.com, since 2026-09-30.
// Redirecting rather than serving keeps every link already delivered working
// (magic links, invites, bookmarks) without the product ever rendering under
// the retired name. The browser carries the #fragment of an auth link across
// a redirect, so a magic link minted for app.muster.partners/app still signs
// its holder in, on the CavScope origin. The one cost is a session already
// stored on a legacy origin: it stays there, and that person signs in again.

// Trailing slashes are stripped so /onboarding and /onboarding/ resolve the
// same. '' is kept meaning root.
function normalize(pathname) {
  return pathname.length > 1 ? pathname.replace(/\/+$/, '') : pathname;
}

// True for an exact path or any child of it, so /sitrep/sample matches the
// /sitrep family without /sitrepfoo also matching.
function isUnder(path, base) {
  return path === base || path.startsWith(base + '/');
}

// ---- security headers ------------------------------------------------------
//
// Every response this file produces carries these. Vercel already sets HSTS on
// these domains (SEC-002 and SEC-003 do not fire), so it is deliberately not
// duplicated here -- two sources for one header is how they drift apart.
//
// The CSP names every inline script by hash, so script-src carries no
// 'unsafe-inline'. Each page is static HTML with one or two inline <script>
// blocks and, on five pages, inline event handlers in the markup; the policy
// allows exactly those by SHA-256 ('sha256-...' for a block, 'unsafe-hashes'
// plus 'sha256-...' for a handler attribute) and refuses any inline script that
// is not in the file. The hashes come from tools/csp/manifest.js, written by
// `node tools/csp/sync.mjs` from the pages themselves, and
// tests/routing/csp-inline.test.ts fails if a page changes and the manifest is
// not regenerated -- in production a stale hash means the browser refuses that
// page's script, so the sync is not optional. Until 2026-10-11 script-src said
// 'unsafe-inline' instead, which CavScope's own SEC-018 reported against this
// site (scan 332): a policy that still allows the one thing injection needs.
//
// style-src still carries 'unsafe-inline'. Every page has one inline <style>
// and hundreds of style="" attributes, and SEC-018 is about script execution;
// hashing styles is a possible next step, not a finished one.
//
// Every allowed origin below is one the pages demonstrably use:
//   cdn.jsdelivr.net       the supabase-js UMD bundle, and html2canvas for the
//                          support widget's screenshot
//   fonts.googleapis.com   the stylesheet <link>
//   fonts.gstatic.com      the font files that stylesheet pulls
//   *.supabase.co          RPC and auth calls, plus realtime over wss
//
// frame-ancestors 'none' is what answers SEC-005; X-Frame-Options is sent too
// for the older browsers that never learned the CSP directive.
const SCRIPT_SRC_HOSTS = "'self' https://cdn.jsdelivr.net";

// The policy for one page's file (e.g. 'app.html'), or for no page at all (a
// static asset, a redirect), where script-src names only the hosts.
export function cspFor(pageFile) {
  const inline = pageFile ? INLINE_SCRIPT_HASHES[pageFile] : null;
  const scriptSrc = [SCRIPT_SRC_HOSTS];
  if (inline) {
    scriptSrc.push(...inline.scripts);
    if (inline.handlers.length) scriptSrc.push("'unsafe-hashes'", ...inline.handlers);
  }
  return [
    "default-src 'self'",
    "base-uri 'self'",
    "object-src 'none'",
    "frame-ancestors 'none'",
    "form-action 'self'",
    "img-src 'self' data:",
    "font-src 'self' https://fonts.gstatic.com",
    "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
    'script-src ' + scriptSrc.join(' '),
    "connect-src 'self' https://*.supabase.co wss://*.supabase.co",
    "upgrade-insecure-requests",
  ].join('; ');
}


const SECURITY_HEADERS = {
  'content-security-policy': cspFor(null),
  'x-frame-options': 'DENY',
  'x-content-type-options': 'nosniff',
  'referrer-policy': 'strict-origin-when-cross-origin',
  // Deny the capability APIs outright rather than listing self: nothing here
  // uses a camera, a microphone, a location or a payment handler, and saying so
  // explicitly is the point of the header.
  'permissions-policy': [
    'accelerometer=()', 'camera=()', 'geolocation=()', 'gyroscope=()',
    'magnetometer=()', 'microphone=()', 'payment=()', 'usb=()',
    'interest-cohort=()',
  ].join(', '),
};

// rewrite() and next() both take an ExtraResponseInit whose `headers` are sent
// on the user response alongside the origin's own -- see the type declarations
// in @vercel/functions/middleware.d.ts. Wrapping both here means a new branch
// added below cannot forget the headers: there is no bare rewrite() or next()
// left in this file to copy from.
// The headers for a response that serves the page file at `pathname`
// ('/app.html'), or the page-less set for anything that is not one of the pages.
function headersFor(pathname) {
  const file = pathname.replace(/^\//, '');
  if (!Object.prototype.hasOwnProperty.call(INLINE_SCRIPT_HASHES, file)) return SECURITY_HEADERS;
  return { ...SECURITY_HEADERS, 'content-security-policy': cspFor(file) };
}

function secureRewrite(url, extraHeaders = {}) {
  return rewrite(url, { headers: { ...headersFor(url.pathname), ...extraHeaders } });
}

// A pass-through. `path` is the request path, so a page asked for by its file
// name (/app.html rather than /app) still gets the policy that names its script.
function secureNext(path = '') {
  return next({ headers: headersFor(path) });
}

// A permanent redirect to the same page on the CavScope host. 308 rather than
// 301 so a POST stays a POST. It carries the security headers too, so no
// response from this file goes out without them.
const CAVSCOPE_ORIGIN = 'https://cavscope.28footsystems.com';

function secureRedirect(path, search) {
  return new Response(null, {
    status: 308,
    headers: { ...SECURITY_HEADERS, location: CAVSCOPE_ORIGIN + path + search },
  });
}

// Where a path on a MUSTER-era host lives on cavscope.28footsystems.com, or
// null when the host is not one of them. Files every host shares (/assets/,
// /.well-known/, /sitemap.xml, /robots.txt) keep their path.
const LEGACY_SITE_HOSTS = ['muster.partners', 'www.muster.partners', 'muster.28footsystems.com'];
const LEGACY_APP_HOSTS = ['app.muster.partners', 'app.muster.28footsystems.com'];
const LEGACY_ONBOARDING_HOSTS = ['onboarding.muster.partners', 'onboarding.muster.28footsystems.com'];
const LEGACY_SITREP_HOSTS = ['sitrep.muster.partners', 'sitrep.muster.28footsystems.com'];

function legacyTarget(host, path) {
  const shared = path.startsWith('/assets/') || path.startsWith('/.well-known/')
    || path === '/sitemap.xml' || path === '/robots.txt' || path === '/llms.txt';
  if (LEGACY_SITE_HOSTS.includes(host)) return path;
  if (LEGACY_APP_HOSTS.includes(host)) {
    // The app hosts' root was the sign-in page; on CavScope root is marketing,
    // so it maps to /signin. Every unknown path there also meant sign-in.
    if (shared || isUnder(path, '/app') || isUnder(path, '/admin')
      || path === '/reset' || path === '/signin') return path;
    return '/signin';
  }
  if (LEGACY_ONBOARDING_HOSTS.includes(host)) return shared ? path : '/onboarding';
  if (LEGACY_SITREP_HOSTS.includes(host)) {
    if (shared) return path;
    return isUnder(path, '/sample') ? '/sitrep/sample' : '/sitrep';
  }
  return null;
}

export default function middleware(request) {
  const host = (request.headers.get('host') || '').toLowerCase();
  const path = normalize(new URL(request.url).pathname);

  // Retired hosts first, before anything else is served from them.
  const legacy = legacyTarget(host, path);
  if (legacy !== null) return secureRedirect(legacy, new URL(request.url).search);

  // Shared static assets (favicons, the logo) must resolve on every host
  // untouched -- without this, a same-origin request like /assets/favicon-32.png
  // would get rewritten to a page below, same as any other path, and the browser
  // would receive that page's HTML mislabeled as an image.
  if (path.startsWith('/assets/')) return secureNext();

  // A vulnerability disclosure policy has to be findable on whichever host
  // someone actually reached, so /.well-known/ is served as the file, the same
  // way /assets/ is, never answered with a page.
  if (path.startsWith('/.well-known/')) return secureNext();

  // Sitemap likewise: one file, served as itself.
  if (path === '/sitemap.xml') return secureNext();

  // llms.txt, for the same reason: an agent asking for it must get the file.
  if (path === '/llms.txt') return secureNext();

  // ---- cavscope.28footsystems.com: one host, every path ---------------------
  //
  // The retired MUSTER hosts split marketing (muster.partners) from sign-in and
  // the workspace (app.muster.partners) because a Supabase session is stored
  // per-origin -- split them and a password sign-in appears to succeed, then
  // the workspace loads signed-out. This host does not need that split:
  // signin.html and app.html already derive every redirect from
  // window.location.origin (WORKSPACE_URL, RESET_URL, admin.html's bounce to
  // '/'), so serving marketing, sign-in, the workspace and the console from
  // one origin costs no page changes and removes the reason for the split
  // entirely, rather than reintroducing it under a new name.
  if (host === 'cavscope.28footsystems.com' || host === 'www.cavscope.28footsystems.com') {
    // One robots.txt covering both the marketing paths and the auth-gated
    // ones -- robots.txt and robots-app.txt merged, because there is no
    // second host here to carry robots-app.txt's "disallow everything".
    if (path === '/robots.txt') {
      return secureRewrite(new URL('/robots-cavscope.txt', request.url));
    }
    if (isUnder(path, '/onboarding')) {
      return secureRewrite(new URL('/onboarding.html', request.url));
    }
    if (isUnder(path, '/sitrep')) {
      // The one static, no-auth, fictional SITREP. Everything else under
      // /sitrep is the signed-in, tenant-scoped viewer.
      if (path === '/sitrep/sample') {
        return secureRewrite(new URL('/sitrep-sample.html', request.url));
      }
      return secureRewrite(new URL('/sitrep.html', request.url));
    }
    if (isUnder(path, '/privacy')) {
      return secureRewrite(new URL('/privacy.html', request.url));
    }
    // The second legal page. Added 2026-10-09 after CavScope's own engine
    // reported PRIV-004 (no Terms of Service link) on this site.
    if (isUnder(path, '/terms')) {
      return secureRewrite(new URL('/terms.html', request.url));
    }
    if (isUnder(path, '/beta')) {
      // Closed 2026-10-02 at the owner's instruction. A temporary redirect, not
      // 308, so it can be reopened without browsers holding on to it. The real
      // control is the insert policy on public.muster_beta_signups
      // (migration 20261002001225); beta.html is kept, unrouted, for reopening.
      return new Response(null, {
        status: 307,
        headers: { ...SECURITY_HEADERS, location: CAVSCOPE_ORIGIN + '/' },
      });
    }
    // The HTML audit. Not a gate either: the page asks
    // cavscope_html_audit_allowed() only to decide what to show, and the
    // cavscope-html-audit function asks again on every request.
    if (path === '/audit/html') {
      return secureRewrite(new URL('/html-audit.html', request.url));
    }
    if (isUnder(path, '/app')) {
      return secureRewrite(new URL('/app.html', request.url));
    }
    // The platform console. Not a second gate -- admin.html holds no role
    // check of its own; cavscope_admin_console() raises 42501 for anyone who
    // is not a super admin, and the page renders whatever the database allows.
    if (isUnder(path, '/admin')) {
      return secureRewrite(new URL('/admin.html', request.url));
    }
    if (path === '/') {
      return secureRewrite(new URL('/index.html', request.url));
    }
    // /signin is the explicit sign-in gate; /reset is the password-reset
    // email's redirect target, handled by signin.html's own type=recovery
    // branch -- there is no reset.html.
    if (path === '/signin' || path === '/reset') {
      // no-store: a sign-in page, and a reset landing that can carry a recovery
      // token in its fragment, must never be kept by a shared cache or a
      // browser's disk cache. It is what CavScope's own AUTH-006 asks of every
      // site it scans, so the product's own login page has to pass it.
      return secureRewrite(new URL('/signin.html', request.url), { 'cache-control': 'no-store' });
    }
    // Anything else falls through to the static file of that name -- an
    // unknown path on this host is a 404, not a silent bounce to the sign-in
    // page. The path is passed so /app.html, asked for directly, carries the
    // CSP that names app.html's own script rather than one that refuses it.
    return secureNext(path);
  }

  return secureNext();
}
