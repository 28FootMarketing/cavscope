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

## 2. Supabase Auth — only once step 1 is verified live

`muster.partners` stays the Site URL and stays on the redirect allowlist indefinitely --
magic-link and invite emails already delivered point there, and retiring it would strand
them, same reasoning as the `*.muster.28footsystems.com` hosts. This step **adds**
`cavscope.28footsystems.com`, it does not replace anything.

- **Redirect allowlist** (Authentication → URL Configuration, project `hjowfnzpomzxazmzywxw`):
  add `https://cavscope.28footsystems.com/**` and, if serving it,
  `https://www.cavscope.28footsystems.com/**`. Cross-check against `middleware.js` the same
  way `docs/CUTOVER.md` had to the first time -- an un-allowlisted `redirect_to` is not an
  error, GoTrue silently substitutes Site URL, and the failure is invisible until someone
  actually clicks a link from the new domain.
- **Site URL**: leave it on `https://app.muster.partners/app` for now. Changing Site URL to
  the new domain is a bigger decision (it is the fallback for any link minted without an
  explicit `redirect_to` -- see `index.html`'s stray-auth-fragment forwarder and
  `docs/EMAIL.md`) and should only happen once `cavscope.28footsystems.com` has been live and
  stable for a while, not on the same day DNS is cut over. When it does move: `index.html`'s
  `setWorkspaceCtaHref()` and `MUSTER_AUTH_HOST` forwarder both have comments pointing at this
  file for the follow-up change they'll need.
- **Sender name: done, 2026-09-26.** `smtp_sender_name` on `hjowfnzpomzxazmzywxw` was
  `MUSTER`, PATCHed to `CavScope` via `.github/workflows/auth-config.yml`'s
  `smtp_sender_name` input, verified by readback (run 36215770285). Sender email
  (`noreply@mail.muster.partners`) is unchanged, as intended -- the domain is verified in
  Resend and mail keeps sending from it regardless of the product name.

## 3. Auth email templates — apply the already-updated repo copies

`supabase/auth-email-templates/*.html` and `manifest.json` now say CavScope (subjects,
body copy, the emblem alt text). The **live** GoTrue templates on
`hjowfnzpomzxazmzywxw` still have whatever `.github/workflows/auth-config.yml` last
pushed, which was the MUSTER copy. Dispatch that workflow with `templates: apply` to push
the six updated templates and subjects and have it verify the readback by checksum, the
same way it did for the original templates on 2026-09-17.

Until this runs, `muster-auth-smoke`'s template-identity check (`html.includes("CavScope is
website assurance by")`) will correctly report the live template as **not** matching the
repo's -- that is the intended signal that this step is still outstanding, not a bug in the
smoke test.

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
