# Dark Zenith — UI Design

Status: initial draft, open for review.

This document is the visual and interaction design spec for the Dark Zenith web UI. It
complements `docs/DESIGN.md`, which remains the source of truth for behavior, routes,
authorization, and error handling — where the two conflict, `DESIGN.md` wins and this
document must be corrected. Scope here: identity, theming, typography, layout, navigation,
and component conventions for every LiveView page.

## Direction: night-sky observatory

The zenith is the point directly overhead — where the sky is darkest and the seeing is
best. The UI takes its identity from that: the calm precision of an observatory — star
atlases, brass instruments, logbooks — applied to a tool whose real content is dense
tabular package data.

Principles:

1. **The data is the hero.** Package tables, NEVRA strings, checksums, and `dnf` commands
   are the product. The astronomy lives in the chrome — identity, palette, empty states —
   never in the data presentation, which stays dense, monospace, and unadorned.
2. **Plain vocabulary.** Astronomy never renames functional concepts. Repositories are
   "Repositories", never "Constellations". Buttons say exactly what they do ("Create
   repository", "Upload RPM", "Revoke key").
3. **Quiet chrome, one signature.** The Zenith Reticle mark (below) is the single
   recurring motif — logo, favicon, spinner, empty states. Everything else is disciplined:
   hairline borders, small radii, restrained motion.
4. **Dark is home.** Dark is the default and the brand theme. The light theme is a
   first-class daytime alternative, not an afterthought.

## Identity

### The Zenith Reticle (logo mark)

A finder-scope reticle aimed straight up: a thin horizon ring with four cardinal ticks,
and a four-pointed star at its center — the zenith. The ring and ticks render in
`currentColor`; the star renders in the primary (Zenith Gold) token.

Reference geometry (24×24 viewBox, stroke 1.5):

```svg
<svg viewBox="0 0 24 24" width="24" height="24" fill="none" xmlns="http://www.w3.org/2000/svg">
  <!-- horizon ring -->
  <circle cx="12" cy="12" r="9" stroke="currentColor" stroke-width="1.5"/>
  <!-- cardinal ticks -->
  <path d="M12 1.5v3M22.5 12h-3M12 22.5v-3M1.5 12h3"
        stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>
  <!-- zenith star -->
  <path d="M12 7 Q12.8 11.2 17 12 Q12.8 12.8 12 17 Q11.2 12.8 7 12 Q11.2 11.2 12 7 Z"
        fill="var(--color-primary)"/>
</svg>
```

Built as a function component (e.g. `<Layouts.zenith_mark class="size-6" />`) so pages,
empty states, and the spinner reuse one definition. Must stay legible at 16 px.

### Wordmark

"DARK ZENITH" set in Spectral Medium, all caps, letterspaced (`tracking` ≈ 0.16em) — the
engraved-brass-plate register. In the nav bar it sits right of the mark, vertically
centered. The wordmark is text, not an image.

### Favicon

The reticle on a Night-navy rounded square, star in Zenith Gold. Replaces the stock
`priv/static/favicon.ico`; ship SVG + ICO + `apple-touch-icon`.

## Color

Two daisyUI themes replace the stock Phoenix pair in `assets/css/app.css`: **night**
(default) and **day**. Values are chosen for WCAG AA (≥ 4.5:1 body text, ≥ 3:1 large
text/UI); verify at implementation time.

### Named palette

| Name        | Hex       | Role                                            |
| ----------- | --------- | ----------------------------------------------- |
| Night       | `#0F1524` | Dark page ground (deep space navy — not black)  |
| Umbra       | `#070B14` | Darkest wells: command blocks, code             |
| Starlight   | `#E8ECF4` | Text on dark                                    |
| Zenith Gold | `#E3B341` | Primary actions, the star in the mark, focus    |
| Vega        | `#A6C8FF` | Links and highlights on dark (blue-white star)  |
| Meridian    | `#8FA3C4` | Secondary/muted elements on dark                |
| Day         | `#F5F7FA` | Light page ground (pale daylight sky, not cream)|
| Ink         | `#141B2E` | Text on light (night navy as daytime ink)       |
| Brass       | `#8A6512` | Primary on light (gold deepened for contrast)   |

### Theme token mapping

| daisyUI token      | night (`#RRGGBB`)      | day (`#RRGGBB`)        |
| ------------------ | ---------------------- | ---------------------- |
| `base-100`         | `#0F1524`              | `#F5F7FA`              |
| `base-200`         | `#0B101C`              | `#EAEEF4`              |
| `base-300`         | `#070B14`              | `#DBE1EA`              |
| `base-content`     | `#E8ECF4`              | `#141B2E`              |
| `primary`          | `#E3B341`              | `#8A6512`              |
| `primary-content`  | `#1A1206`              | `#FAF3E3`              |
| `secondary`        | `#8FA3C4`              | `#4C5C7A`              |
| `secondary-content`| `#0B101C`              | `#F2F5FA`              |
| `accent`           | `#A6C8FF`              | `#2F5FA8`              |
| `accent-content`   | `#0B101C`              | `#F2F6FC`              |
| `neutral`          | `#1D2740`              | `#33405C`              |
| `neutral-content`  | `#D8E0EE`              | `#F2F5FA`              |
| `info`             | `#7AB8E6`              | `#2F6FA8`              |
| `success`          | `#58B77E`              | `#2E7D54`              |
| `warning`          | `#E08A3C`              | `#A85E14`              |
| `error`            | `#E4707B`              | `#B03A48`              |

Semantic `*-content` values follow the same pattern: dark content on the light-ish dark
semitones, pale content on the saturated day semitones.

Shape tokens stay close to the current instrument-panel feel: `--radius-field: 0.25rem`,
`--radius-box: 0.5rem`, `--border: 1.5px`, `--depth: 1`, `--noise: 0`.

Usage rules:

- Zenith Gold is for the one primary action per view, the mark's star, and focus rings.
  It is never body text on Night (use Starlight) and never decorates passive elements.
- Inline links use `accent` (Vega / chart blue), underlined on hover.
- Borders are hairlines: `base-content` at ~8% alpha, or `base-300` on `base-100`.
- Command blocks are always dark (Umbra ground, Starlight text) in **both** themes —
  terminals are dark even at noon.

## Typography

| Role    | Face                     | Usage                                                        |
| ------- | ------------------------ | ------------------------------------------------------------ |
| Display | Spectral (500/600)       | Page titles, landing headline, wordmark. Named for stellar spectral classes; the star-atlas serif. Used with restraint — headings only. |
| UI/body | IBM Plex Sans (400–600)  | Everything interactive and explanatory: labels, buttons, prose, table headers. |
| Data    | IBM Plex Mono (400/500)  | Package names, EVR/NEVRA, arch, slugs, fingerprints, checksums, sizes, commands, API keys. |

All three are OFL-licensed and **self-hosted** (`priv/static/fonts/`, woff2 only,
`@font-face` in `app.css`, license files committed). A self-hosted product must not phone
home to a font CDN. Fallback stacks: `Spectral, Georgia, serif`;
`"IBM Plex Sans", system-ui, sans-serif`; `"IBM Plex Mono", ui-monospace, monospace`.

Scale (Tailwind sizes):

| Level         | Spec                                              |
| ------------- | ------------------------------------------------- |
| Hero          | Spectral 600, `text-5xl`, landing only            |
| Page title    | Spectral 600, `text-2xl`/`text-3xl`               |
| Section head  | Plex Sans 600, `text-lg`                          |
| Eyebrow/label | Plex Sans 600, `text-xs`, uppercase, `tracking-wide`, muted |
| Body          | Plex Sans 400, `text-sm` (UI density); `text-base` for explanatory prose |
| Data          | Plex Mono 400, `text-sm` in tables, `text-xs` for dense metadata |

**Mono rule:** any string a user might paste into a terminal or compare byte-for-byte is
monospace. If it appears in a `dnf` command, a spec file, or a checksum comparison, it is
mono everywhere in the UI.

## Theme behavior

- **Default is dark.** A first-time visitor (no stored `phx:theme`) gets `night`
  regardless of OS preference. The existing three-way toggle (system / light / dark)
  remains; choosing "system" opts back into `prefers-color-scheme`.
- Implementation: the pre-paint script in `root.html.heex` falls back to `"dark"` instead
  of `"system"` when nothing is stored; the daisyUI blocks set `night` as
  `default: true` (no-JS fallback) with theme names `night` → `data-theme="dark"`,
  `day` → `data-theme="light"` kept as today's `dark`/`light` attribute values so the
  toggle JS is unchanged.
- Both themes are fully specified; no page may look designed-for-dark-only in Day.

## App shell

### Top nav bar

One bar on every page, 56 px (`h-14`), `base-100` ground, hairline bottom border.

```
┌────────────────────────────────────────────────────────────────────────────┐
│ ◎ DARK ZENITH   Repositories        [ / Search packages…    ]  ☾  user ▾  │
└────────────────────────────────────────────────────────────────────────────┘
```

Left → right:

1. **Logo** (mark + wordmark), links to `/`. On `< sm` screens the wordmark drops and the
   mark stands alone.
2. **Nav links**: `Repositories` (→ `/repos`). Active link carries a 2 px Zenith Gold
   bottom rule; inactive links are `base-content` at 70%, full on hover.
3. **Global package search**: a compact input (`w-64`, collapses to a search icon button
   below `md` that expands into a full-width row). Placeholder "Search packages…". Focus
   shortcuts: `/` and `Ctrl`/`Cmd`+`K` (ignored while typing in another field). Submits to
   the search results page (scope note below).
4. **Theme toggle**: the existing system/light/dark control, restyled to match.
5. **Account cluster**:
   - Signed out: `Log in` link, plus `Register` when registration is enabled.
   - Signed in: a dropdown menu; the trigger is the user's email (truncated,
     `max-w-[16rem]`) with a chevron. Items: `Settings`, `Admin` (admins only),
     divider, `Log out`. This replaces today's flat link row.
6. **Mobile (`< sm`)**: mark, search icon, and a menu button; the menu contains
   Repositories, the account items, and the theme toggle.

The bar is rendered in `root.html.heex` so it wraps LiveView and controller pages alike;
the current right-aligned utility list is replaced entirely.

### Footer

Hairline top border, single quiet row, `base-content` at 60%:

- Left: reticle glyph + "Dark Zenith" + app version (from `Application.spec/2`).
- Right: `Source` link and "AGPL-3.0-or-later". The Source link satisfies AGPL §13's
  corresponding-source offer for network users, so it must point at the source of the
  running code (see scope notes: `SOURCE_URL` config).

### Layout system

`Layouts.app` gains a width attr; the hardcoded `max-w-2xl` column goes away.

| Width     | Max width  | Used by                                                    |
| --------- | ---------- | ---------------------------------------------------------- |
| `:data`   | `max-w-7xl`| Repo list, repo detail, package pages, upload, admin, search results |
| `:prose`  | `max-w-3xl`| Settings pages, user settings, static/explanatory pages    |
| `:narrow` | `max-w-md` | Auth pages (login, register, reset, confirm)               |

Vertical rhythm: pages open with a title block (breadcrumb, Spectral title, one-line
muted description), `py-8`, sections separated by `space-y-8`.

### Breadcrumbs

Data pages under a repository show a breadcrumb line above the title:
`Repositories / <slug> / <package> / <nevra>` — path segments in Plex Mono, separators
muted, current segment unlinked.

## Components

- **Command block** — the product's most important component: every copy-paste `dnf`
  snippet, `.repo` file, and key-import instruction. Umbra ground in both themes,
  Starlight mono text, optional eyebrow label (e.g. `DNF 5`, `/etc/yum.repos.d/`), a
  copy button (icon → checkmark confirmation) top-right. Multi-line blocks scroll
  horizontally rather than wrap.
- **Tables** — dense catalog style: `text-sm`, uppercase eyebrow-style headers, hairline
  row dividers, row hover `base-200`, mono for name/EVR/arch/size columns, numeric
  columns right-aligned. Sortable headers are real buttons with a small chevron
  indicator. Wide tables scroll inside their own container; columns never crush.
- **Buttons** — one Zenith Gold `btn-primary` per view (the page's main action);
  `btn-outline` secondary; ghost tertiary; `btn-error` destructive. Small size inside
  tables and cards, default size standalone.
- **Badges** — subtle outline/soft styles mapped to semantic tokens: `Public`
  (secondary outline) / `Private` (neutral, lock icon); `Metadata signed` (accent);
  `Auto-sign` (primary outline); signing transition `signing` (warning) / `failed`
  (error); invitation notification `queued` (neutral) / `sent` (success) / `failed`
  (error) / `suppressed` (warning).
- **Empty states** — ghosted reticle (~40 px, 30% opacity), one plain sentence, one
  action. "No packages yet. Upload the first RPM." Never a bare empty table.
- **Loading** — the reticle as spinner: ring and ticks rotate, star stays fixed.
  `prefers-reduced-motion`: static mark plus text. Recolor `topbar.js` progress to
  Zenith Gold.
- **Forms** — labels above fields, muted `text-xs` help below, errors in `error` with
  icon; keep `core_components` structure and daisyUI fieldset styling.
- **Dialogs / confirmations** — destructive flows (repo delete, collaborator removal,
  key removal/revocation) use a modal that states the consequence text `DESIGN.md`
  requires, destructive button in `error`. Repository deletion is type-to-confirm (enter
  the slug).
- **Flash** — existing `flash_group`, restyled to theme tokens; unchanged behavior.

## Page notes

- **Landing (`/`)** — hero: star-field backdrop where star density increases toward the
  top of the viewport (you are looking up; deterministic checked-in SVG, no animation).
  In Day, the backdrop is instead a subtle blue gradient deepening toward the top —
  daytime zenith. Spectral headline, one-sentence subhead, a sample
  `dnf config-manager addrepo …` command block, then `Browse repositories`
  (primary) and `Log in` (ghost). Below: the repository links `DESIGN.md` specifies.
- **Repository list (`/repos`)** — `:data` table: name (mono slug + display name),
  description, package count, visibility badge; `Create new repo` as the page's primary
  action for authenticated users.
- **Repository detail (`/repos/:slug`)** — the money page. Two priorities in order:
  **setup instructions** (tabbed command blocks: DNF 5 / DNF 4 / `.repo` file, plus GPG
  import when applicable, per `DESIGN.md` public/private rules) and the **package
  table** (search field, sortable, mono NEVRA columns). Owner/admin actions (`Upload
  RPM`, settings link, collaborators section) follow.
- **Package detail / version detail** — title block with mono NEVRA; version detail
  renders counts as tabs with lazy-loaded paginated lists per `DESIGN.md`; install
  instructions as command blocks.
- **Upload (`/repos/:slug/upload`)** — drag-and-drop drop zone (dashed hairline border,
  reticle watermark); preview/confirm flow surfaces intent states (`queued`,
  `processing`, `preview_ready` with countdown, terminal errors) using the badge colors.
- **Settings pages (repo + user)** — `:prose`; sections as cards with hairline borders;
  danger zone last, separated, error-toned. GPG key management shows fingerprints in
  mono and the one-time private key display inside a command block with the
  never-shown-again warning.
- **Auth pages** — `:narrow`, centered card, mark above the form. Quiet: no star-field.
- **Admin** — same shell, `:data` width, a sub-nav tab row (Users / Jobs / Transitions /
  Audit / Slugs) under the title. Densest tables in the product; admin pages prefer
  function over flourish.
- **Search results** — `:data` table of matching packages (mono name/EVR/arch, repo
  slug, summary) and matching repositories, grouped; empty state uses the standard
  component.

## Accessibility & motion

- WCAG AA minimum: 4.5:1 body text, 3:1 large text and UI components, in both themes.
- Visible focus: 2 px Zenith Gold outline with offset on every interactive element.
- Full keyboard support; a skip-to-content link precedes the nav; search shortcuts never
  trap focus; sort headers and copy buttons are real buttons.
- `prefers-reduced-motion` disables the spinner rotation and any transition longer than
  150 ms. There is no ambient animation anywhere — the star-field is static.
- Flash regions keep `aria-live="polite"`.

## Scope notes (spec changes required first)

Per project convention, behavior changes are specified in `docs/DESIGN.md` before code:

1. **Global package search** — new surface: results page + query semantics (visibility
   filtering identical to repo browsing, pagination, rate limiting, whether the REST API
   gains a matching endpoint). Blocking for the nav search field; the rest of this
   document does not depend on it.
2. **`SOURCE_URL` config** — footer Source link target (default: the upstream project
   repository), one row in the configuration table.

## Rollout checklist

- [ ] U1 — Foundations: self-hosted fonts (+ licenses), `night`/`day` daisyUI themes
      replacing the stock pair, dark-default theme JS, topbar recolor
- [ ] U2 — Identity: `zenith_mark` component, wordmark, favicon set, footer (needs
      `SOURCE_URL` spec note in `DESIGN.md`)
- [ ] U3 — Shell: top nav (logo, links, account dropdown, mobile menu), `Layouts.app`
      width system, breadcrumbs component
- [ ] U4 — Components: command block with copy, table conventions, badges, empty states,
      reticle spinner, confirmation dialogs (type-to-confirm repo delete)
- [ ] U5 — Pages: landing hero + star-field, repo list, repo detail setup-instructions
      tabs, package pages, upload states, settings, auth
- [ ] U6 — Admin: sub-nav tabs, dense table pass across the five admin views
- [ ] U7 — Global search (blocked on `DESIGN.md` spec): nav field + results page
- [ ] U8 — QA pass: AA contrast verification in both themes, keyboard walkthrough,
      reduced-motion check, responsive sweep, existing LiveView tests updated alongside

Each phase lands with its tests updated (selectors/copy assertions in the existing
LiveView suite) and a screenshot check in both themes.
