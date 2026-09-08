import { rewrite, next } from '@vercel/functions';

// Routes each MUSTER host to its own static file. vercel.json's declarative
// rewrites cannot branch on the Host header (only real code can), so this uses
// Vercel's Routing Middleware instead.
//
// Two host families are served:
//
//   muster.partners                  the main site. Paths, not subdomains:
//                                    /, /onboarding, /sitrep, /sitrep/sample
//   *.muster.28footsystems.com       the original subdomain layout, still live
//
// The subdomain hosts are deliberately kept working. Magic-link emails already
// sent point at app.muster.28footsystems.com/app, and onboarding invites are in
// people's inboxes; retiring those hosts would strand every link already
// delivered. They can be dropped once nothing in the wild references them.

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

export default function middleware(request) {
  const host = (request.headers.get('host') || '').toLowerCase();
  const path = normalize(new URL(request.url).pathname);

  // Shared static assets (favicons, the logo) must resolve on every host
  // untouched -- without this, a same-origin request like /assets/favicon-32.png
  // would get rewritten to a page below, same as any other path, and the browser
  // would receive that page's HTML mislabeled as an image.
  if (path.startsWith('/assets/')) return next();

  // ---- muster.partners: the main site, path-routed --------------------------
  if (host === 'muster.partners' || host === 'www.muster.partners') {
    if (isUnder(path, '/onboarding')) {
      return rewrite(new URL('/onboarding.html', request.url));
    }
    if (isUnder(path, '/sitrep')) {
      // The one static, no-auth, fictional SITREP. Everything else under
      // /sitrep is the signed-in, tenant-scoped viewer.
      if (path === '/sitrep/sample') {
        return rewrite(new URL('/sitrep-sample.html', request.url));
      }
      return rewrite(new URL('/sitrep.html', request.url));
    }
    if (path === '/') {
      return rewrite(new URL('/index.html', request.url));
    }
    // Anything else falls through to the static file of that name.
    return next();
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
  // shipped to it.
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
    if (isUnder(path, '/app')) {
      return rewrite(new URL('/app.html', request.url));
    }
    return rewrite(new URL('/signin.html', request.url));
  }

  // ---- onboarding.muster.28footsystems.com ---------------------------------
  if (host === 'onboarding.muster.28footsystems.com') {
    return rewrite(new URL('/onboarding.html', request.url));
  }

  // ---- sitrep.muster.28footsystems.com -------------------------------------
  if (host === 'sitrep.muster.28footsystems.com') {
    if (isUnder(path, '/sample')) {
      return rewrite(new URL('/sitrep-sample.html', request.url));
    }
    return rewrite(new URL('/sitrep.html', request.url));
  }

  return next();
}
