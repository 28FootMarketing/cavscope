import { rewrite, next } from '@vercel/functions';

// Routes each CavScope host to its own static file. vercel.json's declarative
// rewrites cannot branch on the Host header (only real code can), so this uses
// Vercel's Routing Middleware instead.
//
// Three host families are served:
//
//   cavscope.28footsystems.com       the current brand's one host, path-routed
//                                    for everything: /, /onboarding, /sitrep,
//                                    /sitrep/sample, /beta, /privacy, /signin,
//                                    /app, /admin, /reset. See the block below
//                                    for why this one host can do what the
//                                    legacy pair below needed two hosts for.
//   muster.partners                  the previous brand's main site. Paths,
//                                    not subdomains: /, /onboarding, /sitrep,
//                                    /sitrep/sample, /beta, /privacy
//   *.muster.28footsystems.com       the original subdomain layout, still live
//
// The muster.partners / *.muster.28footsystems.com hosts are deliberately kept
// working, unchanged, alongside the new domain -- not redirected away from.
// Magic-link emails already sent point at app.muster.28footsystems.com/app,
// and onboarding invites are in people's inboxes; retiring those hosts would
// strand every link already delivered. They can be dropped once nothing in
// the wild references them. See docs/BRAND-CUTOVER.md for what still has to
// change outside this repo (DNS, the Vercel project domain, Supabase's Site
// URL and redirect allowlist) before cavscope.28footsystems.com actually
// resolves in production -- this file is ready for that day, not proof it
// has arrived.

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
// muster.partners (SEC-002 and SEC-003 do not fire), so it is deliberately not
// duplicated here -- two sources for one header is how they drift apart.
//
// The CSP is honest about what these pages actually are. They are static HTML
// with one inline <style> and one inline <script> each, so 'unsafe-inline' is
// required on both style-src and script-src until those blocks are extracted
// to files. That is a real weakening: this policy stops an attacker loading a
// script from a host that is not jsdelivr, and stops the pages being framed,
// but it does not stop injected inline script. Extracting the inline blocks and
// dropping 'unsafe-inline' from script-src is the next step, not a finished one.
//
// Every allowed origin below is one the pages demonstrably use:
//   cdn.jsdelivr.net       the supabase-js UMD bundle, on all six pages
//   fonts.googleapis.com   the stylesheet <link>
//   fonts.gstatic.com      the font files that stylesheet pulls
//   *.supabase.co          RPC and auth calls, plus realtime over wss
//
// frame-ancestors 'none' is what answers SEC-005; X-Frame-Options is sent too
// for the older browsers that never learned the CSP directive.
const CSP = [
  "default-src 'self'",
  "base-uri 'self'",
  "object-src 'none'",
  "frame-ancestors 'none'",
  "form-action 'self'",
  "img-src 'self' data:",
  "font-src 'self' https://fonts.gstatic.com",
  "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
  "script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net",
  "connect-src 'self' https://*.supabase.co wss://*.supabase.co",
  "upgrade-insecure-requests",
].join('; ');

const SECURITY_HEADERS = {
  'content-security-policy': CSP,
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
function secureRewrite(url) {
  return rewrite(url, { headers: SECURITY_HEADERS });
}

function secureNext() {
  return next({ headers: SECURITY_HEADERS });
}

export default function middleware(request) {
  const host = (request.headers.get('host') || '').toLowerCase();
  const path = normalize(new URL(request.url).pathname);

  // Shared static assets (favicons, the logo) must resolve on every host
  // untouched -- without this, a same-origin request like /assets/favicon-32.png
  // would get rewritten to a page below, same as any other path, and the browser
  // would receive that page's HTML mislabeled as an image.
  if (path.startsWith('/assets/')) return secureNext();

  // A vulnerability disclosure policy has to be findable on whichever host
  // someone actually reached, so /.well-known/ is shared the same way /assets/
  // is. Without this the app hosts' catch-all below would answer
  // /.well-known/security.txt with signin.html, and a researcher looking for
  // somewhere to report would find a login page.
  if (path.startsWith('/.well-known/')) return secureNext();

  // Sitemap likewise: it is one file describing muster.partners, and the app
  // hosts have their own robots.txt below rather than sharing this one.
  if (path === '/sitemap.xml') return secureNext();

  // ---- cavscope.28footsystems.com: one host, every path ---------------------
  //
  // The legacy pair below splits marketing (muster.partners) from sign-in and
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
    if (isUnder(path, '/beta')) {
      return secureRewrite(new URL('/beta.html', request.url));
    }
    if (isUnder(path, '/app')) {
      return secureRewrite(new URL('/app.html', request.url));
    }
    // The platform console. Not a second gate -- admin.html holds no role
    // check of its own; muster_admin_console() raises 42501 for anyone who
    // is not a super admin, and the page renders whatever the database allows.
    if (isUnder(path, '/admin')) {
      return secureRewrite(new URL('/admin.html', request.url));
    }
    if (path === '/') {
      return secureRewrite(new URL('/index.html', request.url));
    }
    // /signin is the explicit sign-in gate; /reset is the password-reset
    // email's redirect target, handled by signin.html's own type=recovery
    // branch -- there is no reset.html, same as the legacy app hosts.
    if (path === '/signin' || path === '/reset') {
      return secureRewrite(new URL('/signin.html', request.url));
    }
    // Anything else falls through to the static file of that name, same as
    // muster.partners below -- an unknown path on this host is a 404, not a
    // silent bounce to the sign-in page.
    return secureNext();
  }

  // ---- muster.partners: the main site, path-routed --------------------------
  if (host === 'muster.partners' || host === 'www.muster.partners') {
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
    if (isUnder(path, '/beta')) {
      return secureRewrite(new URL('/beta.html', request.url));
    }
    if (path === '/') {
      return secureRewrite(new URL('/index.html', request.url));
    }
    // Anything else falls through to the static file of that name.
    return secureNext();
  }

  // ---- the app hosts: app.muster.partners, app.muster.28footsystems.com -----
  //
  // Both serve the SAME two pages, and that is deliberate rather than
  // duplication. signin.html and app.html must be reachable on one shared
  // origin, because a Supabase session created by a password sign-in is stored
  // per-origin -- split them across hosts and sign-in appears to succeed, then
  // the workspace loads signed-out. So a host serves both or neither.
  //
  // Root is the real client-facing sign-in gate; the workspace SPA itself lives
  // at /app so an already-authenticated redirect (from signin.html, a magic
  // link, or onboarding.html) has somewhere to land that isn't the sign-in page
  // again. /signin is kept as an alias to avoid breaking the link already
  // shipped to it. /admin is the platform console -- same origin for the same
  // session reason, gated in Postgres rather than by the route.
  //
  // /reset is deliberately NOT a branch of its own: it is the redirect target
  // of a password-reset email, and signin.html is the page that handles it
  // (it detects type=recovery and shows the new-password form instead of
  // bouncing to the workspace). It falls into the catch-all below. Don't
  // "fix" that by pointing /reset somewhere else -- there is no reset.html,
  // and the recovery session only exists on the URL that Supabase redirected
  // to. It does have to be on the Supabase project's allowed redirect list;
  // see docs/EMAIL.md.
  if (host === 'app.muster.partners' || host === 'app.muster.28footsystems.com') {
    // The app hosts get their own robots.txt, not the marketing site's. Every
    // path here is a sign-in gate or a tenant-scoped page that renders
    // signed-out to a crawler, so the answer is disallow everything -- and the
    // catch-all below would otherwise serve signin.html as the robots file.
    if (path === '/robots.txt') {
      return secureRewrite(new URL('/robots-app.txt', request.url));
    }
    if (isUnder(path, '/app')) {
      return secureRewrite(new URL('/app.html', request.url));
    }
    // The standalone platform console. It lives on this host rather than a
    // console-only one for the same reason /app does: a Supabase session is
    // stored per-origin, so a console on its own host would load signed-out for
    // someone who signed in here. It is not a second gate -- admin.html holds no
    // role check of its own; muster_admin_console() raises 42501 for anyone who
    // is not a super admin, and the page renders whatever the database allows.
    if (isUnder(path, '/admin')) {
      return secureRewrite(new URL('/admin.html', request.url));
    }
    return secureRewrite(new URL('/signin.html', request.url));
  }

  // ---- onboarding.muster.28footsystems.com ---------------------------------
  if (host === 'onboarding.muster.28footsystems.com') {
    return secureRewrite(new URL('/onboarding.html', request.url));
  }

  // ---- sitrep.muster.28footsystems.com -------------------------------------
  if (host === 'sitrep.muster.28footsystems.com') {
    if (isUnder(path, '/sample')) {
      return secureRewrite(new URL('/sitrep-sample.html', request.url));
    }
    return secureRewrite(new URL('/sitrep.html', request.url));
  }

  return secureNext();
}
