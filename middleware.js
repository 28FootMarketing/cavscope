import { rewrite, next } from '@vercel/functions';

// Routes each MUSTER subdomain to its own static file. vercel.json's
// declarative rewrites cannot branch on the Host header (only Next.js's
// own client-side middleware can), so this uses Vercel's Routing
// Middleware instead, which runs real code per request.
export default function middleware(request) {
  const host = request.headers.get('host') || '';

  if (host === 'app.muster.28footsystems.com') {
    return rewrite(new URL('/app.html', request.url));
  }
  if (host === 'onboarding.muster.28footsystems.com') {
    // Retired: the scripted "pre-flight scan" wizard duplicated what the
    // super admin's real URL runner now does for real (see app.html's
    // admin console). Route the old subdomain to the one remaining demo
    // asset instead of a dead page.
    return rewrite(new URL('/sitrep-sample.html', request.url));
  }
  if (host === 'sitrep.muster.28footsystems.com') {
    const path = new URL(request.url).pathname;
    if (path === '/sample' || path.startsWith('/sample/')) {
      return rewrite(new URL('/sitrep-sample.html', request.url));
    }
    return rewrite(new URL('/sitrep.html', request.url));
  }
  return next();
}
