import { rewrite, next } from '@vercel/functions';

// Routes each MUSTER subdomain to its own static file. vercel.json's
// declarative rewrites cannot branch on the Host header (only Next.js's
// own client-side middleware can), so this uses Vercel's Routing
// Middleware instead, which runs real code per request.
export default function middleware(request) {
  const host = request.headers.get('host') || '';
  const path = new URL(request.url).pathname;

  // Shared static assets (favicons, the logo) must resolve on every
  // subdomain untouched -- without this, a same-origin request like
  // /assets/favicon-32.png on app.muster... would get rewritten to
  // app.html below, same as any other path, and the browser would receive
  // that page's HTML mislabeled as an image.
  if (path.startsWith('/assets/')) return next();

  if (host === 'app.muster.28footsystems.com') {
    // Root is the real client-facing sign-in gate; the workspace SPA itself
    // lives at /app so an already-authenticated redirect (from signin.html,
    // a magic link, or onboarding.html) has somewhere to land that isn't
    // the sign-in page again. /signin is kept as an alias to avoid breaking
    // the link already shipped to it.
    if (path === '/app' || path.startsWith('/app/')) {
      return rewrite(new URL('/app.html', request.url));
    }
    return rewrite(new URL('/signin.html', request.url));
  }
  if (host === 'onboarding.muster.28footsystems.com') {
    return rewrite(new URL('/onboarding.html', request.url));
  }
  if (host === 'sitrep.muster.28footsystems.com') {
    if (path === '/sample' || path.startsWith('/sample/')) {
      return rewrite(new URL('/sitrep-sample.html', request.url));
    }
    return rewrite(new URL('/sitrep.html', request.url));
  }
  return next();
}
