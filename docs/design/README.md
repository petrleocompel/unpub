# unpub web client design

The design of the single-page client in `ui/`, made against [DESIGN_BRIEF.md](../DESIGN_BRIEF.md). It covers the tokens, the component set and every screen of the brief at 1440 px and 390 px, in light and dark.

| Path                      | What is there                                                                                                                                        |
| ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| `screens/`                | PNG of every artboard: `NN-screen-<width>-<theme>.png`. Start here.                                                                                  |
| `html/`                   | The same artboards as plain HTML with `html/unpub.css`; open `html/03-package-list.html` in a browser to inspect markup and spacing.                 |
| `artboards/`              | The source of the Design canvas (`.dc.html` files, `unpub.css`, `canvas.json`), to re-import or edit on claude.ai.                                   |
| `tokens.css`              | The design tokens in the shadcn/ui theme format. The same values are in `ui/src/index.css`, which is the copy the client uses.                       |

The canvas itself is a private claude.ai Design artifact owned by the author; ask for it to be shared if you want to comment on it there.

## Screens

| #   | Screen                                                         | States shown                                                                          |
| --- | -------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| 00  | Foundations                                                    | colour tokens with values, type scale, spacing, radii, elevation, focus, icons, mark |
| 01  | Components                                                     | header, buttons, form controls, badges, tabs, package row, table, secret box, menu, alerts, toasts, chart, skeleton/empty/error |
| 02  | States                                                         | list and page skeletons, offline banner, empty registry, no results, error with retry, 403, 500, toasts, delete / transfer / rotate dialogs |
| 03  | 1 · Package list                                               | anonymous visitor, default sort, pagination with page size                           |
| 04  | 2 · Package page, README                                       | uploader logged in, table of contents, full sidebar                                  |
| 05  | 2 · Package page, Versions                                     | retracted version selected, Actions menu open as an administrator                   |
| 06  | 2 · Package page, Install                                      | discontinued package with “replaced by”, copy confirmation                           |
| 07  | 2 · Package page, Stats                                        | package proxied from pub.dev, 30-day chart, per-version downloads                     |
| 08  | 3 · Login                                                      | private registry; wrong password, rate limited (429), empty                          |
| 09  | 6 · Not found                                                  | suggestion and search                                                                |
| 10  | 4 · Account                                                    | profile, change password, token just created (one-shot box), token table             |
| 11  | 5 · Admin, Overview                                            | readiness, counts, recent publishes, failed deliveries                               |
| 12  | 5 · Admin, Users                                               | filters, row menu, 409 “last administrator” toast                                    |
| 13  | 5 · Admin, Packages                                            | search, source filter                                                                |
| 14  | 5 · Admin, Package                                             | versions with retract/restore/delete, discontinue form, uploaders, danger zone       |
| 15  | 5 · Admin, Audit log                                           | filters, one row expanded to JSON                                                    |
| 16  | 5 · Admin, Webhooks                                            | list with delivery summaries, create dialog open                                     |
| 17  | 5 · Admin, Webhook                                             | edit form, secret just rotated, deliveries, payload and signature headers            |
| 18  | 5 · Admin, Settings                                            | read-only configuration by section, redacted secrets, environment variable per key   |

## Direction

**One look, nameable: “calm slate”.** Slate neutrals with a faint blue cast, one Dart-adjacent blue as the only accent, and state colours (green, amber, red) used only for status. Nothing decorative: no gradients, no illustrations, no tinted page backgrounds. A tool that is open all day should be quiet; the colour that is there means something.

**Two densities.** Public pages use 15 px README text, 16–20 px row padding and 24–48 px section gaps. The dashboard uses 13 px tables with 40 px rows (50 rows ≈ 2 000 px, readable without zebra stripes), 12–20 px gaps and a 232 px sidebar.

**Two surfaces.** `--background` is the content plane; `--surface` is one step off it and marks chrome that frames content: the package header band, the dashboard sidebar, table headers, card footers, the footer. In dark mode `--surface` is darker than the background, so content cards lift instead of sink.

**Brand.** The wordmark is “unpub” in the UI sans at 650 weight with tight tracking, after a mark: a rounded square in `--primary` holding a “u” with a small box dropping into it, a package landing in the registry. The mark is an inline SVG that takes its colours from the theme (`fill-primary`, `stroke-primary-foreground`), so it follows light and dark; `ui/public/favicon.svg` is the same drawing with fixed colours. It reads at 16 px.

**Type.** System UI sans and system monospace, bundled nothing, which satisfies the CSP and renders as SF on macOS, Segoe on Windows. Monospace marks everything a developer would copy: package names in lists of dependencies, versions, hashes, commands, token prefixes, event names and configuration keys.

**Colour never alone.** Every status carries an icon or a word as well as a tint: Retracted (ban icon, red tint), Discontinued (archive icon, amber tint), Latest (star, blue tint), Prerelease (flask), From pub.dev (cloud), Disabled (alert icon), delivery statuses (dot plus “Delivered / Pending / Failed”). Text pairs are at least 4.5 : 1 in both themes (checked: foreground, muted-foreground, primary, destructive, success and warning on background, surface, card, secondary and accent; the lowest is warning on accent in light, 4.52 : 1).

**Accessibility as drawn.** Real buttons, links, inputs with labels, `role="switch"`, `aria-current` on navigation and tabs, `aria-sort` on sorted columns, `aria-busy` on skeletons, icon-only buttons with `aria-label`, a role="img" summary on the chart plus a Table toggle. The focus ring is 2 px `--ring` with a 2 px offset everywhere; inputs add a 3 px soft halo.

## Information architecture

**Public pages borrow pub.dev’s map, not its look.** Search lives in the header on every page (`/` focuses it). The package page keeps pub.dev’s order: breadcrumb, name and version, description, a meta line (published, uploader, downloads), badges, then tabs README / Changelog / Versions / Install / Stats, with a right sidebar for version selector, SDK constraints, platforms, dependencies, uploaders and links. A Dart developer finds things where they expect them.

**The package header is a band.** Name, version, notices and tabs sit on `--surface` above the tab content, so notices (retracted, discontinued, proxied) are read before the README, and the tabs read as navigation of that band rather than floating in the content.

**Notices sit above the tabs, not in the sidebar.** A retracted or discontinued state changes what the reader should do, so it is a full-width alert with its consequence spelled out (“`dart pub get` no longer picks it for new resolutions; lockfiles keep working”) and the way out (link to latest or the replacement).

**Actions are one menu, grouped by scope.** The Actions menu on the package header has three groups: this version (retract / restore), the package (discontinue, uploaders), and, for administrators only, under a labelled “Administrator” group, transfer and the two deletes in destructive red. The same dialogs open from the admin package page.

**The dashboard is one shell for Account and Admin.** Same header, a left sidebar of sections, compact tables, dialogs for confirmations, toasts for results. Account has three sections (Profile, Password, API tokens); Admin has Overview, Users, Packages, Audit log, Webhooks, Settings and a Metrics link. On phones the sidebar becomes a “Sections” button that opens a drawer, and wide tables scroll horizontally with a sticky first column.

**Overview answers “is anything wrong?” first.** Readiness badges for MongoDB and storage sit in the page heading; the Webhooks count tile turns red with “N failed in 24 h”, and the sidebar shows the same count on Webhooks.

## Changes from the brief

- **SDK filter as a segmented control** (All / Dart / Flutter) instead of a select: three options, always visible, one click. The sort stays a select. Applied in `ui/` (`SegmentedControl` on the package list).
- **Webhook events** are the server’s real list (`package.published`, `version.retracted`, `version.unretracted`, `version.deleted`, `package.discontinued`, `package.continued`, `package.deleted`), not the brief’s generic examples.
- **Theme toggle in the header, as the client already has it.** The brief puts it in the user menu, but anonymous visitors on a public registry have no user menu, so the header keeps its icon button (system / light / dark). The Components board also shows it as a segmented control inside the user menu, an optional addition.
- **Settings show the overriding environment variable under every key** (`UNPUB_SERVER_PUBLIC_URL`), and keys still at their default value are muted, so an operator sees what was actually configured.
- **Password hints say 8 characters**, the server’s `minPasswordLength`.
- **Webhook detail explains verification next to the secret** rather than only in the payload preview, because rotating is when people update their receivers.
- **404 suggests the closest package name** (“Did you mean my_company_core?”) above the search. The client asks the search for five names and picks the closest by edit distance; nothing is suggested when no name is close.
- **The Versions board has a Dart SDK column**, but the API has no SDK constraint per version, so the client keeps a Downloads column there. The rest of board 05 is applied: the Show retracted switch and an archive download on every row.

## Applied to `ui/`

Phase 7 of [the roadmap](../ROADMAP.md) applied every board to the client. Behaviour and API calls stayed the same, apart from the additions listed under the boards below. `ui/README.md`, "Restyling", says how to change the look from here.

**Tokens and foundations (board 00).** `src/index.css` holds the light and dark values of `tokens.css`, including `--surface`, `--info`, `--code`, `--chart-*`, `--scrim` and `--elevation-*` (as `shadow-xs … shadow-lg`). One global focus ring, 2 px `--ring` with a 2 px offset, replaces the per-control rings. README and CHANGELOG styles follow board 04; their headings keep the height of the sticky header (`--header-height`, two rows below 640 px) clear when reached by a fragment link.

**Components (board 01).** The hand-written shadcn/ui components in `src/components/ui` (button sizes and `destructive-outline`, badge tones, alerts, inputs, switch, table with a sticky first column, dialog, sheet, dropdown menu, tooltip) and the new `segmented.tsx`, whose pill chrome the default tabs share; line tabs with a primary underline. In `src/components`: `CodeBlock` with a title and a `$` prompt, `HashText`, `Initials`, the bar chart, the pager with a page size, `EmptyState` / `ErrorState` with an icon tile, the secret box and toasts.

**States (board 02).** List and page skeletons, the offline banner, empty registry and no results, error with retry, the forbidden page and the delete, transfer and rotate dialogs.

**Public pages (boards 03 to 09).** The header with the mark and the search (a row of its own on phones), the footer on `--surface`. The package list with the segmented SDK filter and its rows. The package page as a band on `--surface` with breadcrumb, meta line, badges, notices and line tabs; the README with an "On this page" table of contents that follows the section in view; Versions with the Show retracted switch, hashes and archive downloads; Install as numbered steps with copyable commands, and on a private registry the `dart pub token add` command to copy; Stats with tiles, the chart and its table view, and downloads per version. The login page with the countdown of a 429. The not found page with the closest name.

**Account and administration (boards 10 to 18).** One dashboard shell in `src/components/dashboard` for both: the sidebar on `--surface` (a Sections drawer on phones) with the failed deliveries of the last 24 hours on Webhooks, the page heading, panels, a compact table. Account with Profile, Password and API tokens, the token command with a prompt. The overview with readiness badges, tiles, recent publishes and failed deliveries; users as a compact table with the last-administrator toast; packages and package moderation; the audit log as a compact table with a details row; webhooks as rows with delivery badges and the detail as drawn; settings as cards by section with the environment variable under every key.

The unit tests, the end-to-end smoke test (`npm run test:e2e`, which fails on any console error and so on any CSP violation) cover the result. The screenshots of the implemented screens, on a seeded registry, are in [`docs/screenshots`](../screenshots/README.md).
