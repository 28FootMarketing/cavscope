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
    return rewrite(new URL('/onboarding.html', request.url));
  }
  if (host === 'sitrep.muster.28footsystems.com') {
    return rewrite(new URL('/sitrep.html', request.url));
  }
  return next();
}
