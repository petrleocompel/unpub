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

- **SDK filter as a segmented control** (All / Dart / Flutter) instead of a select: three options, always visible, one click. The sort stays a select. Not applied to `ui/` yet (it still uses the native select).
- **Webhook events** are the server’s real list (`package.published`, `version.retracted`, `version.unretracted`, `version.deleted`, `package.discontinued`, `package.continued`, `package.deleted`), not the brief’s generic examples.
- **Theme toggle in the header, as the client already has it.** The brief puts it in the user menu, but anonymous visitors on a public registry have no user menu, so the header keeps its icon button (system / light / dark). The Components board also shows it as a segmented control inside the user menu, an optional addition.
- **Settings show the overriding environment variable under every key** (`UNPUB_SERVER_PUBLIC_URL`), and keys still at their default value are muted, so an operator sees what was actually configured.
- **Password hints say 8 characters**, the server’s `minPasswordLength`.
- **Webhook detail explains verification next to the secret** rather than only in the payload preview, because rotating is when people update their receivers.
- **404 suggests the closest package name** (“Did you mean my_company_core?”) above the search; this needs a fuzzy match on the server or client and can ship later without changing the layout.

## Applied to `ui/`

These are changed in the client to match the design; everything else already followed the brief and only picks up the new tokens.

- `src/index.css`: new light and dark values; new `--surface`, `--info` and `--elevation-*` tokens mapped to `bg-surface`, `text-info` and `shadow-xs … shadow-lg`; README heading and table styles.
- `src/layout/header.tsx`: the new `Mark` and wordmark; nav item with an accent background when active; 60 px header.
- `public/favicon.svg`: the new mark.
- `src/components/badges.tsx`: tinted tones for Latest, Retracted, Discontinued, Disabled and delivery statuses; SDK badge with a shape-coded dot (square Dart, round Flutter).
- `src/pages/admin/layout.tsx`: full-height sidebar on `--surface`, active item as a raised chip with a blue icon, “Administration” label, content padding.
- `src/layout/root.tsx`, `footer.tsx`, `search-box.tsx`, `pages/package-list.tsx`, `pages/package.tsx`, `components/ui/tabs.tsx`: surface footer, search field, list rows, package title and line-style tabs with a primary underline.

Run `npm run format`, `npm run lint`, `npm run typecheck` and `npm test -- --run` in `ui/` after pulling these changes; they were not run when the changes were made.
