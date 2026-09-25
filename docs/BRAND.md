# CavScope brand identity

Adopted 2026-09-26. This is the implementation spec for the visual identity layer
on top of the CavScope name migration in `CLAUDE.md`'s brand note and
`docs/BRAND-CUTOVER.md`. Those two cover the product *name*; this covers what it
*looks like* -- logo, palette, type, icons, and how a page is supposed to use
them.

**Scope of what shipped with this doc**, read this before anything else:

- The mark, the icon sprite, and the semantic design tokens are real, committed,
  tested files -- `assets/brand/*.svg`, `assets/brand/icons.svg`,
  `assets/tokens.css`.
- The new tokens are **additive**. Nothing an existing page already renders
  changed color. `--surface` is still `#0c1527` and `--text-muted` is still
  `#8e9fb8` on every page today -- see "Two names this collides with" below for
  exactly why, and what the two-step promotion looks like when someone signs off
  on it.
- Day mode (light theme) is **specified, not shipped**. This product has no
  light/dark toggle today. The values are in this document so a future toggle
  starts from agreed colors instead of guessing them under deadline.
- The mark itself is a clean, hand-authored geometric placeholder, not final
  production art. It is good enough to ship as the favicon and emblem today
  (both are live, real files -- see "What's actually live" below) and good
  enough to design from. A polish pass by an actual designer, and the raster
  exports this document lists, are the honest next steps -- see the end of this
  file.

## What's actually live right now

- `assets/favicon-32.png`, `assets/favicon-180.png`, `assets/favicon-192.png` --
  regenerated from the new mark, same filenames the nine pages already
  reference, so no markup changed.
- `assets/cavscope-emblem.png` (replaces `assets/muster-emblem.png`, which is
  deleted) -- the mark used inline next to the wordmark in the site header;
  every reference to it, across all nine pages and the six auth email
  templates, was updated to the new filename.
- `assets/tokens.css` -- the new semantic tokens, additive, described below.

Everything else in this document (icon sprite adoption across the app, the
reskin pass that would move `--surface`/`--text-muted` onto the brand palette,
day mode wired to a real toggle, print/social assets) is specified here and not
yet wired into the live pages. Each says so at the point it's discussed.

## 1. Brand overview

**CavScope** is web assurance by 28 Foot Systems: continuous, evidence-backed
visibility into a website's security, accessibility, privacy, and AI-readiness
posture. The identity has to read as **precision, visibility, and assurance**
-- not a scanner tool, not a badge, not a toy.

Core line: **Precision. Visibility. Assurance.**
Secondary line: **Monitor. Assure. Advance.**
Descriptor: **Web Assurance by 28 Foot Systems.**

Don't repeat "CavScope" on every screen. One clear mention per view (header,
email subject, report title) reads as confident; five reads as insecure.

## 2. Logo rationale

The mark is a hybrid of two ideas the product actually does:

- **A reticle/crosshair**, shaped as the letter **C** -- open on the east side
  rather than a closed ring, so it reads as both "precision targeting" and the
  first letter of the name at once. It is not a gunsight: there is no closed
  circle-and-cross military reticle, no dot-and-post, nothing that reads as a
  weapon sight rather than a surveying/measurement instrument.
- **A lens**, centered in the opening -- the inspection element. CavScope looks
  at a site the way a lens looks at a subject: it observes and records, it
  doesn't intervene. The small highlight dot is the one representational
  detail, keeping the mark from reading as a flat ring-and-circle icon.

Both ideas map directly to the tagline: the reticle is precision, the lens is
visibility, and the two together, rendered in gold, are assurance -- a mark
worth trusting.

What it deliberately avoids: no badge shape (shield, star-burst, seal), no
tactical/military styling (no dot-and-crosshair gunsight, no stencil type, no
camo or olive-drab), no mascot, no rounded "friendly SaaS blob" style. This is
an enterprise security vendor's mark, not a consumer app's.

## 3. Approved lockups

All files are in `assets/brand/`. Every one is a plain, dependency-free SVG --
no external fonts required to render (they reference Cinzel/Plus Jakarta Sans
by name for on-brand rendering inside this app, where those fonts are already
loaded, and fall back to Georgia/system-ui elsewhere).

| File | Use |
|---|---|
| `cavscope-logo-primary-dark.svg` | Horizontal lockup, symbol + wordmark, for dark backgrounds. The default -- headers, footers, email banners. |
| `cavscope-logo-primary-light.svg` | Same lockup, for white/light backgrounds. Only the wordmark color changes ("Cav" goes from white to Deep Black); the symbol is unchanged. |
| `cavscope-logo-vertical-dark.svg` | Stacked lockup for square or narrow spaces, dark backgrounds. |
| `cavscope-logo-vertical-light.svg` | Same, for light backgrounds. |
| `cavscope-logo-symbol-dark.svg` / `cavscope-logo-symbol-light.svg` | Symbol alone, no wordmark. Identical artwork (the gold/black two-tone mark has enough contrast on both); shipped as two files to match a consistent naming convention for background-aware assets, not because the art differs. |
| `cavscope-logo-monochrome-black.svg` | Single-color (`#0B0B0B`) mark for light or busy backgrounds where the two-tone version loses contrast -- print, a watermark, a favicon fallback. |
| `cavscope-logo-monochrome-white.svg` | Single-color (`#FFFFFF`) mark for dark backgrounds outside the app's own gold accent -- a dark third-party surface, a footer on a photo. |
| `cavscope-favicon.svg` | Simplified mark (ring + lens, no crosshair ticks or inner reticle lines) for anything under ~48px, where the fine detail disappears and just adds noise. Source for `favicon-32.png`. |
| `cavscope-app-icon.svg` | 512×512 master with the Deep Black rounded-square background, for every app-icon-shaped export (favicon-180/192, and any future apple-touch/android-chrome sizes). |
| `icons.svg` | The product icon sprite -- see §6. |

## 4. Color palette

Six brand colors, plus the product's existing functional status colors, which
this identity does not touch (see §4.3).

### 4.1 Brand colors

| Token (raw) | Hex | Role |
|---|---|---|
| `--cs-gold` | `#D4AF37` | Accent. The one color that means "CavScope" on sight. |
| `--cs-black` | `#0B0B0B` | Primary background (night mode). |
| `--cs-charcoal` | `#1E1E1E` | Surface -- cards, panels, raised elements (night mode). |
| `--cs-slate` | `#6B6B6B` | Secondary/muted text, and the base for hairline borders. |
| `--cs-light-gray` | `#D9D9D9` | Borders on light backgrounds; a light-mode surface tint. |
| `--cs-white` | `#FFFFFF` | Primary text on dark, primary background on light. |

### 4.2 Semantic tokens (night mode -- what ships today)

Defined in `assets/tokens.css`, synced into every page's `<style>` by
`tools/tokens/sync.mjs`. Use these, not the raw `--cs-*` values, in any new
component -- that's the whole point of a token layer.

| Semantic token | Value | Notes |
|---|---|---|
| `--background` | `var(--cs-black)` | New. Page-level background for new work. |
| `--surface-alt` | `color-mix(in srgb, var(--cs-charcoal) 100%, white 6%)` | New. A raised panel a shade lighter than surface. |
| `--border` | `color-mix(in srgb, var(--cs-light-gray) 100%, transparent 78%)` | New. Subtle hairline on a dark surface -- light gray at low opacity, not full-strength (full-strength light gray on black is a glare, not a border). |
| `--text-primary` | `var(--cs-white)` | New. |
| `--text-secondary` | `var(--cs-slate)` | New. |
| `--accent` | `var(--cs-gold)` | New. |
| `--accent-hover` | `color-mix(in srgb, var(--cs-gold) 100%, white 15%)` | New. Lightened gold for a hover/active state. |
| `--accent-soft` | `color-mix(in srgb, var(--cs-gold) 22%, transparent)` | New. Gold at low alpha, for a soft badge/highlight background. |
| `--success` / `--warning` / `--error` | `var(--emerald)` / `var(--amber)` / `var(--rose)` | New names, aliasing the **existing** status hues. See §4.3. |
| `--focus-ring` | `var(--cs-gold)` | New. |

### 4.3 Status colors are functional, not decorative -- out of scope

`--emerald`, `--amber`, `--rose`, `--purple`, `--teal`, `--cyan` already carry
real meaning across the product: severity pills (`pill-critical`, `pill-high`,
`pill-medium`, `pill-low`), control status, alert state. **This identity does
not collapse them into gold.** A security-assurance product where "critical
finding" and "the primary CTA" are the same color is a worse product, not a
more on-brand one. `--success`/`--warning`/`--error` above are new *names* for
those same existing colors, added so new components can reach for a semantic
name instead of memorizing which hue means what -- the hues themselves are
unchanged.

### 4.4 Two names this collides with -- read before touching `--surface` or `--text-muted`

The product already has tokens named `--surface` (`#0c1527`) and `--text-muted`
(`#8e9fb8`), driving every card, panel, and secondary text label on all nine
live pages today. The brand palette's equivalents are `--cs-charcoal`
(`#1E1E1E`) and `--cs-slate` (`#6B6B6B`).

**This document does not redefine those two names.** Doing so would silently
reskin the entire live product -- every card background, every piece of muted
text, everywhere -- the moment `tools/tokens/sync.mjs` runs, with no one having
looked at the result. That's a real visual decision, not a token rename.
`assets/tokens.css` names the two target values (`--cs-surface-target`,
`--cs-text-muted-target`) so the eventual reskin pass promotes them instead of
re-deriving them. Until that pass happens, existing pages keep their current
navy-based surface and blue-gray muted text; only genuinely new UI should reach
for the brand tokens.

### 4.5 Day mode (specified, not wired -- see §7)

| Semantic token | Day-mode value |
|---|---|
| `--background` | `var(--cs-white)` |
| `--surface-alt` | `var(--cs-light-gray)` |
| `--border` | `color-mix(in srgb, var(--cs-slate) 100%, transparent 65%)` |
| `--text-primary` | `var(--cs-black)` |
| `--text-secondary` | `var(--cs-slate)` |
| `--accent` | `var(--cs-gold)` |
| `--accent-hover` | `color-mix(in srgb, var(--cs-gold) 100%, black 12%)` |
| `--accent-soft` | `color-mix(in srgb, var(--cs-gold) 14%, transparent)` |

The equivalent of `--surface` (target `--cs-surface-target`) in day mode is a
near-white neutral, `#F4F4F5` -- Charcoal itself is too dark to read as a card
on a white page; a light theme needs its own surface tone, not literally the
dark theme's charcoal.

## 5. Typography

Unchanged from the existing product -- already on-brand, no reason to replace
it:

- **Display/serif -- `--font-serif` (Cinzel).** Wordmark, page titles, report
  headers. Cinzel's engraved-capital character already reads as "assurance
  document," which is exactly right for CavScope.
- **Body -- `--font-sans` (Plus Jakarta Sans).** UI text, body copy.
- **Mono -- `--font-mono` (JetBrains Mono).** Evidence ids, hashes, code,
  anything that is literally data.

`--font-body` / `--font-display` remain aliases of `--font-sans` / `--font-serif`
for the landing page's existing call sites -- see `assets/tokens.css`.

## 6. Icon system

`assets/brand/icons.svg` is a sprite of `<symbol>` elements, one consistent
grammar throughout: 24×24 viewBox, 1.75 stroke, round caps and joins,
`fill="none"`, `stroke="currentColor"`. Color always comes from CSS at the call
site -- never hardcode a color inside a symbol.

```html
<svg class="icon" width="20" height="20" aria-hidden="true" style="color: var(--accent)">
  <use href="/assets/brand/icons.svg#icon-scan"></use>
</svg>
```

Always pair an icon with a visible label or an `aria-label` on the parent --
per this repo's own tooltip rule in `CLAUDE.md`, nothing here is self-explanatory
from a glyph alone.

**This is a new system, not a replacement for anything live.** The product
today uses emoji and text pills for status (see `app.html`'s `🤖 Copy Fix`,
`📡` in beta-notify, and the `pill-critical`/`pill-high`/etc. classes) --
there is no existing custom icon set to migrate away from. Adopting this
sprite into the app's nav, cards, and buttons is real UI work across a 339KB
page and deserves its own pass with visual review, not a blind find-and-replace
alongside a brand doc.

| Icon | Concept | Label |
|---|---|---|
| `icon-scan` | Viewfinder corner brackets + a scan line | Scan |
| `icon-monitor` | An eye | Monitor |
| `icon-assure` | Shield with a checkmark | Assure |
| `icon-reports` | A page with summary lines | Reports |
| `icon-alerts` | A bell | Alerts |
| `icon-security` | A padlock | Security |
| `icon-compliance` | Shield with a star | Compliance |
| `icon-performance` | Ascending bars with a trend line | Performance |
| `icon-support` | A headset | Support |
| `icon-settings` | A gear | Settings |
| `icon-users` | Two overlapping figures | Users |
| `icon-integrations` | Two linked blocks | Integrations |
| `icon-websites` | A globe | Websites |
| `icon-sitrep` | A page with a small reticle mark | SITREP -- ties the flagship report back to the brand mark rather than looking like a generic document |
| `icon-backups` | Stacked disks | Backups |

## 7. Light mode / dark mode implementation

**Night mode is what ships.** Every one of the nine pages is dark-themed
today, and the new tokens in §4.2 are live in that theme now.

**Day mode is specified in §4.5 and not wired to anything.** Building a real
toggle is a separate, larger project: it needs a `data-theme` mechanism, a
persisted preference, and -- the actual work -- an audit of every page's
hardcoded `rgba()` values that aren't tokens today (`--bg-grid`,
`--shadow-glow`, and similar are hand-tuned against the dark background and
would need day-mode equivalents, not just an inverted token). Flagging that
scope honestly here rather than shipping a toggle that looks right on the
first screen and breaks on the fifth.

When that project happens, the pattern to follow (matching how this repo's own
tooling documentation writes CSS elsewhere) is:

```css
:root { /* night mode values, as in assets/tokens.css */ }
@media (prefers-color-scheme: light) {
  :root:not([data-theme="dark"]) { /* day mode values, from §4.5 */ }
}
:root[data-theme="light"] { /* day mode values, explicit override */ }
```

## 8. Spacing, clearspace, minimum size

- **Clearspace:** keep empty space around the mark equal to at least the width
  of one crosshair tick (roughly 1/8 of the mark's total width) on every side.
  Don't crowd it against a page edge, a rule line, or another logo.
- **Minimum size:** the full mark (with crosshair ticks and inner reticle
  lines) reads clearly down to ~48px. Below that, use `cavscope-favicon.svg`
  (ring + lens only) -- verified at 32px in the live favicon.
- **Never** stretch the mark to a non-1:1 aspect ratio, rotate it, recolor the
  ring to anything but gold/black/white per the approved variants, or place it
  on a background that drops the ring below roughly 3:1 contrast.

## 9. Do / don't

**Do**
- Use `cavscope-logo-primary-dark.svg` as the default lockup; reach for
  `-light` only when the background is genuinely light.
- Use the semantic tokens (`var(--accent)`, `var(--text-primary)`, …) in new
  CSS, not raw hex or the `--cs-*` raw-palette names directly.
- Keep severity/status colors as they are; cite `--success`/`--warning`/
  `--error` by name in new code so a future contributor doesn't have to
  remember that `--emerald` means "success."

**Don't**
- Don't redefine `--surface` or `--text-muted` without a dedicated visual QA
  pass across all nine pages -- see §4.4.
- Don't recolor the reticle ring or the lens to anything outside the approved
  variants.
- Don't use the icon sprite's raw fill color -- always `stroke="currentColor"`
  and set color via CSS.
- Don't repeat "CavScope" more than once per view. See §1.

## 10. File structure

This is a multi-page static-HTML app with no bundler and no `/src` directory
(`CLAUDE.md`: "every page here is self-contained... no stylesheet request").
The generic `/src/styles/` and `/src/components/brand/` layout a typical SPA
brand package would propose does not fit this codebase, and building it would
mean adding the exact render-blocking, single-point-of-failure architecture
`assets/tokens.css`'s own header explains this repo deliberately avoids. The
structure below is that convention, extended:

```
assets/
  tokens.css                    -- source of truth for every CSS custom property
  brand/
    cavscope-logo-primary-dark.svg
    cavscope-logo-primary-light.svg
    cavscope-logo-vertical-dark.svg
    cavscope-logo-vertical-light.svg
    cavscope-logo-symbol-dark.svg
    cavscope-logo-symbol-light.svg
    cavscope-logo-monochrome-black.svg
    cavscope-logo-monochrome-white.svg
    cavscope-favicon.svg        -- simplified mark, small-size source
    cavscope-app-icon.svg       -- 512x512 master, source for every raster icon
    icons.svg                   -- product icon sprite
  favicon-32.png                -- live, referenced by all nine pages
  favicon-180.png               -- live (apple-touch-icon)
  favicon-192.png               -- live
  cavscope-emblem.png           -- live, inline header mark
docs/
  BRAND.md                      -- this file
tools/
  tokens/sync.mjs                -- unchanged; still the only writer of the token block
```

No `/public`, no `/src` -- every page and asset is served from the repo root or
`/assets/`, per `middleware.js`.

## 11. Component guidance

Mapped to the classes that actually exist in the live pages today (grep'd, not
invented): `.btn-primary`, `.btn-ghost`, `.btn-amber`, `.pill` with
`.pill-critical` / `.pill-high` / `.pill-medium` / `.pill-low` /
`.pill-approved` / `.pill-pending` / `.pill-in-review` / `.pill-system` /
`.pill-client`. Each page defines its own copy of these rules (self-contained
pages, see §10) -- there is no shared component CSS file to edit once.

- **Buttons.** `.btn-primary` is the accent-filled call to action; it should
  resolve to `var(--accent)` / `var(--accent-hover)` rather than a hardcoded
  teal once a page's button styles are touched. `.btn-ghost` is the
  bordered/transparent secondary -- `var(--border)` / `var(--text-primary)`.
  `.btn-amber` stays amber; it is a status-adjacent action style, not a brand
  chrome color (see §4.3).
- **Pills/badges.** Severity and state pills keep their existing hues
  (`pill-critical` → rose, `pill-high` → amber, etc.) -- these are the
  functional colors from §4.3, unchanged.
- **Cards / panels.** New cards should use `var(--surface-alt)` for a raised
  panel against `var(--background)`, with `var(--border)` for the hairline.
  Existing `.price-card`, `.table-row` and similar keep using `--surface-card`
  etc. until the reskin pass in §4.4.
- **Nav / sidebar.** The statusbar and sidebar brand mark
  (`.brand`/`.brand-mark`/`.brand-word`) already render `cavscope-emblem.png`
  next to the "CavScope" wordmark -- no change needed, it's live.
- **Focus states.** New interactive elements should set
  `outline: 2px solid var(--focus-ring); outline-offset: 2px;` on
  `:focus-visible`, matching the pattern the tooltip system already uses (see
  `CLAUDE.md`'s tooltip section) rather than inventing a new focus treatment.

## 12. Recommended next steps

In priority order:

1. **Design review of the mark.** `assets/brand/*.svg` are real, clean,
   geometric placeholders -- good enough to ship as the live favicon/emblem
   today, not a final production asset. A professional pass (refined curves,
   optical spacing on the wordmark, an actual brand designer's eye) is the
   honest next step before this becomes the permanent mark.
2. **Export the remaining raster sizes** for anything beyond what's live
   today -- `android-chrome-512x512.png`, an OG/social share image, a
   print-resolution logo. This session rendered PNGs via headless Chromium
   (no ImageMagick/rsvg-convert was available in this environment); the same
   approach works for any additional size, or a designer can re-export from
   the SVG masters in any vector tool.
3. **The `--surface` / `--text-muted` reskin** (§4.4) -- a deliberate,
   visually-reviewed pass, not a token edit.
4. **Icon sprite adoption** into the actual app UI (§6) -- real product work,
   scoped separately.
5. **Day mode**, only once there's an actual reason a user needs it (§7).
