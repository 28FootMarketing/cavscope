# Magic-link sign-in

What ships, what has to be configured outside this repository, and what to check
before trusting it with a paying customer.

Read [`docs/EMAIL.md`](EMAIL.md) first if you have not. The single most expensive
mistake available here is treating auth email as application email. They are
different paths and only one of them sends sign-in links.

## The flow, end to end

```
user types email in signin.html  (app.muster.partners/)
  -> normalizeEmail + isValidEmail        (client, signin.html)
  -> supabase-js signInWithOtp            (browser -> GoTrue)
     shouldCreateUser: false
     emailRedirectTo: <origin>/app
  -> GoTrue mints the token and renders 03-magic-link.html
  -> GoTrue hands finished MIME to Resend over SMTP
  -> Resend delivers
  -> user clicks the link in their inbox
  -> GoTrue verifies the token, redirects to <origin>/app#access_token=...
  -> middleware.js serves app.html for /app on that host
  -> supabase-js detectSessionInUrl consumes the fragment, stores the session
  -> app.html onAuthStateChange sees the session, renders the workspace
```

**There is no server-side callback route, and there should not be one.** This
repository is static HTML behind Vercel Routing Middleware. It has no Node
server, no API routes and no `@supabase/ssr`. The token exchange happens in
`supabase-js` in the browser, which is Supabase's supported flow for a static
client. Adding a callback route would mean introducing a server runtime purely
to move an exchange that already works.

**The application never sees or sends the token.** GoTrue mints it, renders the
template and hands the finished message to Resend. No application code path can
produce a valid magic link, which is why there is no Resend REST call in the
sign-in path and must not be one.

## Redirect safety

`WORKSPACE_URL` and `RESET_URL` in `signin.html` are built from
`window.location.origin`. Neither reads the query string, so there is no
attacker-controlled redirect input and therefore nothing to allowlist in the
page. `tests/auth/signin.test.ts` asserts that every `location.href =` in the
file targets `WORKSPACE_URL`, and that the page never reads `location.search`.

The real allowlist is Supabase's, and it is not optional: GoTrue silently
substitutes **Site URL** for any `emailRedirectTo` that is not on the list, which
looks exactly like a link that took the user to the wrong place for no reason.

## Configuration that is not in this repository

### Supabase — Authentication → URL Configuration

Site URL and the redirect allowlist are listed in
[`docs/EMAIL.md`](EMAIL.md#2-url-configuration--authentication--url-configuration).
`/reset` must be on that list or password recovery lands on a page with no form.

### Supabase — Authentication → Emails

Paste `supabase/auth-email-templates/03-magic-link.html` into the **Magic Link**
template. Subject: `Your secure MUSTER sign-in link`.

Templates live in project config, not in Postgres. No migration applies them and
no MCP call sets them. Editing one only in the dashboard loses it the next time
someone pastes from that directory.

### Supabase — Authentication → Rate Limits

GoTrue enforces the real limit; the 60-second countdown in `signin.html` is the
client half, so a user sees a timer instead of a 429 they cannot act on. It is
not a security control and does not replace the server limit.

The default is roughly 2 emails per hour per address, which is too low for a
product where a person may legitimately request a link, miss it, and request
another. Raise it deliberately rather than discovering it during a demo.

### Resend

Sending domain and sender address are in
[`docs/EMAIL.md`](EMAIL.md#1-smtp--authentication--emails--smtp-settings).
The API key used as the SMTP password needs sending permission only.

## About `login@auth.muster.partners`

This is a **new subdomain that does not exist today**. Auth mail currently sends
from `noreply@mail.muster.partners`, on a domain already verified in Resend with
DKIM and a Return-Path in place.

Moving the sender is not a code change. It requires, in order:

1. Add `auth.muster.partners` as a domain in Resend.
2. Publish the DNS records **Resend generates for that domain**. They are unique
   per domain: a DKIM public key, a Return-Path/bounce CNAME, and an SPF value.
   Do not copy them from `mail.muster.partners` and do not take them from any
   document, including this one. Read them out of the Resend dashboard.
3. Wait for Resend to report the domain verified.
4. Change **Sender email** in Supabase → Authentication → Emails → SMTP Settings
   to `login@auth.muster.partners`.
5. Send a real magic link and confirm the `From` header on the delivered
   message, not the API response.

Until step 4, changing the address anywhere in this repository changes nothing:
the sender is set in the Supabase dashboard, not in code.

### Why a separate subdomain is worth doing

Authentication mail and product mail have different reputations. If an alert
send ever gets a spam complaint, a shared sending domain lets that complaint
degrade delivery of sign-in links, which is the one message a customer cannot
work around. Splitting them means a reputation problem on one cannot lock people
out of the product.

### What must be true of `auth.muster.partners` before it is used

Verify each of these against the live record, not against a plan:

- **SPF** at `auth.muster.partners`, containing exactly the sender Resend
  specifies for that domain.
- **DKIM** at the selector Resend issues. The key is generated per domain and is
  never written down here.
- **DMARC alignment.** `muster.partners` publishes `p=reject`, which subdomains
  inherit unless `_dmarc.auth.muster.partners` overrides it. A subdomain that
  inherits `reject` before its own SPF and DKIM verify will have its mail
  rejected outright. Publish and verify the subdomain's own records **before**
  sending anything from it.
- **Resend domain status** reads verified.
- **A delivered message**, checked in an inbox. A 2xx from an API is a queue
  acknowledgement, not a delivery.

MUSTER's own `EMAIL-*` rules check the first three from the outside. Run a scan
against `auth.muster.partners` once it is live and confirm it comes back clean.

## Verification checklist

Run this against production, not a preview.

- [ ] Request a link at `https://app.muster.partners/` with a real account
- [ ] Email arrives; `From` is the configured sender
- [ ] Subject reads `Your secure MUSTER sign-in link`
- [ ] The button and the fallback URL both work
- [ ] Clicking it lands on `/app` signed in, not on `/`
- [ ] `sb-<ref>-auth-token` is present in local storage for that origin
- [ ] Sign out; `/app` shows the signed-out state and no stale session survives a reload
- [ ] Open the same link again: it fails with the expired/used message, not a blank page
- [ ] Request a second link within a minute: the resend control is disabled and says how long
- [ ] Request a link for an address with no account: identical confirmation, no email
- [ ] Tab to the resend control during the cooldown: it cannot be activated
- [ ] Submit an invalid address: the field is marked invalid, focused, and announced

The two that catch the most: **reusing an old link**, and **an address with no
account**. Both are supposed to be uneventful, and both are how a leak shows up.
