# CavScope brand cutover

This repo now presents the product as **CavScope** (still internally identified by the
`muster` schema, RPC prefix, migration names, function names and the `muster.partners` /
`*.muster.28footsystems.com` hostnames -- see the brand note at the top of `CLAUDE.md`).
Everything in this file is **not done by editing code**; it is dashboard, DNS and registrar
work outside this repository, in the same spirit as `docs/CUTOVER.md`'s ordered remainder
for the Supabase project migration. Nothing here is required for the app to keep working:
`muster.partners` and `app.muster.partners` are unaffected and stay fully live (see
`middleware.js`). This is the list for making `cavscope.28footsystems.com` actually resolve
as the primary domain, in the order that keeps nothing broken partway through.

## 1. DNS + Vercel — make the domain resolve

- Point `cavscope.28footsystems.com` at Vercel (the registrar for `28footsystems.com`,
  outside this repo).
- Add `cavscope.28footsystems.com` (and, if wanted, `www.cavscope.28footsystems.com`) as a
  domain on this Vercel project. `middleware.js` already routes both -- see "one host, every
  path" in that file -- so no code change is needed once the domain is attached.
- Verify all nine pages resolve there before touching anything below: `/`, `/onboarding`,
  `/app`, `/admin`, `/sitrep`, `/sitrep/sample`, `/beta`, `/signin`, `/privacy`, plus
  `/robots.txt` (should serve `robots-cavscope.txt`'s content), `/sitemap.xml` and
  `/.well-known/security.txt`.

## 2. Supabase Auth — done, 2026-09-28

`muster.partners` stays on the redirect allowlist indefinitely -- magic-link and invite
emails already delivered point there, and retiring it would strand them, same reasoning as
the `*.muster.28footsystems.com` hosts. Nothing below removed anything; every step here only
ever added.

- **Redirect allowlist: done.** `https://cavscope.28footsystems.com/app`,
  `.../reset`, `.../**`, and `https://www.cavscope.28footsystems.com/**` were merged in via
  `.github/workflows/auth-config.yml`'s new `add_redirect_urls` input (union, not replace --
  the job fails if the readback is missing anything that was already there or anything just
  requested). Verified by readback: 11 entries before, 15 after, all 11 original entries
  still present (run 36440705061).
- **Site URL: done.** Moved from `https://app.muster.partners` to
  `https://cavscope.28footsystems.com`, via the same workflow's `site_url` input with
  `apply: true`. Proven the way `docs/EMAIL.md` says this has to be proven -- not by reading
  the readback of the value itself, but by the `allowlist:control` probe in
  `muster-auth-smoke`, which asks for a host that must be rejected and reports where GoTrue
  actually falls back to: `https://cavscope.28footsystems.com/#<fragment>` (run against
  `sentinel-qa-verify@28footmarketing.com`, `checked_at` 2026-09-28T15:05:38Z). The other
  smoke-test steps still report `app.muster.partners` because they explicitly request that
  host by name to prove it is *still* honoured -- that is correct and expected, not a sign
  the move didn't take.
- **The prerequisite this needed first, also done:** `index.html`'s stray-auth-fragment
  forwarder was hardcoded to send every arrival to `app.muster.partners`. Since
  `cavscope.28footsystems.com` has no separate app host (`setWorkspaceCtaHref()` right below
  it in the same file, and `middleware.js`), a link falling back to that root now needs a
  same-origin `/signin` redirect, not a cross-origin hop to the legacy host -- otherwise
  moving Site URL here would have quietly bounced every stray fragment straight back to
  `app.muster.partners` regardless, undoing the point of the change. Fixed and covered by two
  new cases in `tests/auth/landing-auth-fragment.test.ts`; all prior assertions, including the
  loop guard, still pass unmodified.
- **Sender name: done, 2026-09-26.** `smtp_sender_name` on `hjowfnzpomzxazmzywxw` was
  `MUSTER`, PATCHed to `CavScope` via the same workflow's `smtp_sender_name` input, verified
  by readback (run 36215770285). Sender email (`noreply@mail.muster.partners`) is unchanged,
  as intended -- the domain is verified in Resend and mail keeps sending from it regardless
  of the product name.

**Not yet done, and not attempted here:** `muster-auth-smoke`'s own hardcoded app-host
constant still targets `app.muster.partners` for the steps that ask for a redirect by name.
That is a deliberate, narrower follow-up -- updating what the smoke test itself proves,
now that Site URL has actually moved -- not a gap in the move itself.

## 3. Auth email templates — done, confirmed 2026-09-26

`supabase/auth-email-templates/*.html` and `manifest.json` say CavScope (subjects, body
copy, the emblem alt text), and the **live** GoTrue templates on `hjowfnzpomzxazmzywxw`
match: a read-only `templates: report` dispatch of `auth-config.yml` (run 36214625077) read
back `mailer_subjects_magic_link => Your secure CavScope sign-in link`,
`mailer_subjects_recovery => Reset your CavScope password`,
`mailer_subjects_invite => You have been invited to CavScope`, and the rest of the six, all
CavScope-branded. This paragraph previously said this step was still outstanding; it was
stale -- a `templates: apply` run had already landed it before that stale text was written.

## 4. Things that do not need to change

Listed so nobody goes looking for a problem that isn't one.

- **Stripe.** Payment Link metadata (`tier`, `stage`) and the products/prices themselves are
  unaffected by the brand name. Nothing to do.
- **GHL tag taxonomy** (`src:`/`product:`/`intent:`). Values like `muster_partner` are
  internal identifiers, not displayed to anyone; unaffected.
- **`mcp/server-card.json`, `AGENTS.md`.** Already updated in this repo (name, description,
  `organization.url` now `https://cavscope.28footsystems.com`). The API contract
  (`x-muster-api-key` header, `mk_` key prefix, the `muster-agent` function path) is
  unchanged on purpose -- renaming a live header or key prefix breaks every existing
  integration for a cosmetic gain.
- **The scan engine's own User-Agent.** `Mozilla/5.0 (compatible; CavScope-Scanner/1.0;
  +https://muster.partners)` and `muster-verify-site`'s equivalent already say CavScope; both
  still point their `+https://...` URL at `muster.partners` because that host resolves today
  and `cavscope.28footsystems.com` does not yet. Repoint both at
  `+https://cavscope.28footsystems.com` once step 1 is verified live -- not before, for the
  exact reason the URL was ever pointed at a real page in the first place (see the comment
  above the `UA` constant in `supabase/functions/muster-scan/index.ts`).

## 5. Done: the GitHub repository rename

**`28FootMarketing/muster` was renamed to `28FootMarketing/cavscope` on 2026-09-25**, on
Anthony's explicit instruction after the tradeoff below was put to him. GitHub redirects
the old clone/web URLs to the new name, so nothing broke immediately; `documentation.source`
/ `documentation.readme` in `mcp/server-card.json` were repointed at `/cavscope` in the same
change. Two things worth re-verifying, since a redirect is not the same as every consumer
having actually moved:

- Any clone or CI configuration outside this repo that hardcodes `.../muster` (not
  `.../cavscope`) still resolves via GitHub's redirect today, but that redirect is not
  guaranteed to be permanent if the old name is ever reused elsewhere. Repoint anything
  found still using it.
- Vercel's Git integration is tied to the repo by ID, not name, so it kept deploying without
  reconnecting -- confirmed by the preview build on PR #146 succeeding after the rename.

The original tradeoff, kept for the record: every clone URL, CI badge, and the two
`documentation.*` URLs above resolved through `/muster` before this. Actions secrets are
keyed to the repo, not its name, so they were unaffected by the rename itself.

## 6. Optional, cosmetic, needs an explicit decision (not done here)

None of these block anything above.

- **Renaming the Vercel project** in the dashboard. Purely cosmetic (the project's internal
  name, not a domain); no functional effect either way.
- **The Notion pages** `MUSTER — Product Standard Operating Procedure` and its Glossary
  child page. `docs/GLOSSARY.md` in this repo now says CavScope throughout; the Notion
  source it was published from still says MUSTER, since Notion is outside this repository.
- **`package.json`'s `"name": "muster"`**. Private, unpublished, never customer-visible;
  left as the internal identifier it is.

## 7. Done 2026-09-30: MUSTER retired as a direction, not kept as a codename

The owner's direction on 2026-09-30 reversed this file's earlier position that MUSTER stays as
an internal codename: the target is that nothing carries the name. Done in this repo that day:

- Every MUSTER-era host (`muster.partners`, `www.`, `app.`, `onboarding.`, `sitrep.`, and the
  `*.muster.28footsystems.com` originals) answers with a 308 to the same page on
  `cavscope.28footsystems.com` (`legacyTarget()` in `middleware.js`). Links already delivered
  keep working, auth fragments included; a session already stored on an old origin does not
  carry over, so that person signs in again.
- The remaining visible leftovers in the pages: one sentence in `app.html`, the canonical links
  on `app.html` and `signin.html`, the landing page's workspace links, onboarding's "Go to your
  workspace" links, the beta page footer, the hostnames in `privacy.html`, and two strings in
  the admin console.
- A MUSTER scanner found still running on the old shared project (cron jobid 150, active since
  about 2026-09-15) was paused. See `CLAUDE.md`.

Also done the same day: `privacy.html` and `.well-known/security.txt` now give
`support@` / `security@mail.cavscope.28footsystems.com`, and mail to those (and to the old
`mail.muster.partners` pair) is forwarded to the owner by `cavscope-inbound-mail`. Still open,
and why: the backend names follow `docs/RENAME-PLAN.md`; the old domains stay attached in
Vercel and on the Supabase redirect allowlist, because the redirect only works while they do.
