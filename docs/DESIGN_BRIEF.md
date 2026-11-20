# Design brief for Claude Design: unpub web client

Use this document as the prompt for Claude Design. Paste it whole, then attach screenshots of the current server-rendered pages if available. The output should be a design system and screen designs that can be exported as React + Tailwind components compatible with shadcn/ui.

## What unpub is

unpub is a self-hosted package registry for Dart and Flutter, run by a team or a company for its private packages. It is one Dart server with MongoDB, deployed as one Docker image, and it speaks the same API as pub.dev, so `dart pub` and `flutter pub` use it directly. Teams publish packages to it, consume them in their apps, and administrators manage users, tokens, packages, webhooks and the audit log. It can also proxy and cache public packages from pub.dev.

This brief is for the single-page web client (React, TypeScript, Tailwind, shadcn/ui). It replaces nothing: a plain server-rendered HTML version of every page stays as the no-JavaScript fallback under `/classic`. The client talks to a JSON API with session cookies.

## Audiences

1. **Consumers**: Dart and Flutter developers who look up a package, read its README and changelog, copy the install snippet and check versions and dependencies. Most visits. Often arrive by a direct link from a pubspec, a chat or a search.
2. **Publishers**: developers who publish packages from the command line and use the UI to check what landed, retract a broken version, manage uploaders of their package and manage their own API tokens.
3. **Administrators**: operators who create users and set roles, moderate packages (discontinue, retract, delete, transfer ownership), configure webhooks, read the audit log, check settings and metrics.
4. **Readers**: accounts with read-only access on a private registry; they log in to browse and create read tokens for CI.

## Design direction

- **Public pages feel familiar to pub.dev users.** The package list and package page follow the layout conventions of pub.dev (search first, package header with name, version, publisher info and badges, tabs for README / Changelog / Versions / Install, a sidebar with metadata), so a Dart developer knows where things are. Do not copy pub.dev visuals; borrow the information architecture.
- **Account and administration are a dashboard.** A left sidebar with sections, dense but readable tables, filters above tables, dialogs for confirmations, toasts for results, in the spirit of GitHub settings or the Vercel dashboard.
- **Brand**: the product name is "unpub", lowercase. No logo exists; propose a simple wordmark and a favicon. The palette may nod to Dart's blues but should work for a company-internal tool that is open all day: calm, high contrast, little decoration. Light and dark themes with equal care; dark follows the system by default and has a manual toggle.
- **Typography**: one UI sans and one monospace for code, versions, hashes and snippets. Fonts must be bundled with the client (no Google Fonts or other third-party origins; the Content-Security-Policy forbids them). System font stacks are acceptable.
- **Density**: public pages comfortable, dashboard compact. Tables must hold 50 rows without pagination feeling cramped.
- **Responsive** from 360 px to 1440 px and beyond. On phones the sidebar becomes a drawer, tables become cards or scroll horizontally with a sticky first column.
- **Accessibility**: WCAG 2.1 AA contrast, visible focus rings, every control labelled, dialogs trap focus, no information conveyed by colour alone (retracted, discontinued, disabled states also get text or an icon).
- **No inline styles or scripts in the delivered markup**: the server sends a strict Content-Security-Policy. Designs that need per-element inline styles (gradients computed per row, arbitrary colours from data) must express them through classes or CSS variables set from JavaScript.

## Global elements

- **Header** on every page: wordmark linking home, search box (always present, `/` focuses it, Esc clears), navigation "Packages", and on the right either "Log in" or the user menu (email, role badge, links to Account and Admin for administrators, theme toggle, Log out). On a private registry (`readAccess: authenticated`) anonymous visitors see only the login page.
- **Footer**: "unpub <version>", link to the source repository, link to the classic (no-JavaScript) version of the current page, link to the API documentation.
- **Toasts** for results of actions (created, saved, deleted, copied, failed with the server message).
- **Confirmation dialogs** for irreversible actions, the destructive ones requiring the user to type the name (delete package) or tick a checkbox (rotate secret, transfer ownership).
- **One-shot secrets** (new API token, new or rotated webhook secret): shown once in a prominent box with a copy button and a warning that it will not be shown again; the box disappears on navigation.
- **States** for every data view: loading (skeletons, not spinners, for lists and detail pages), empty (with a hint of what to do), error (message from the server, retry), and not found (404 page with search).
- **Badges**: Dart, Flutter, retracted, discontinued, "replaced by <name>", proxied from pub.dev, prerelease, latest, disabled (users), admin / publisher / reader (roles), read / publish (token scopes), delivery statuses (pending, delivered, failed).

## Screens

### 1. Package list (home, `/packages`)

- Search as you type over names and descriptions; results update without a full reload, URL reflects the query.
- Filters: SDK (all / Dart / Flutter), show discontinued (off by default). Sort: best match (only with a query), downloads, recently updated, name.
- Each row: name (link), latest version, short description, badges (Flutter/Dart, discontinued, proxied), updated date, download count. 20 per page, pagination with page numbers, page size selector (20/50/100).
- Empty registry state: explain how to publish the first package with the `dart pub publish` command and the hosted URL.
- No-results state with the query echoed and a reset.

### 2. Package page (`/packages/<name>`, `/packages/<name>/versions/<version>`)

- Header: name, selected version (latest by default), published date, uploader, download count, badges, notice banners for discontinued (with "replaced by" link), retracted version, prerelease, proxied package (link to pub.dev).
- Tabs: README (rendered markdown with heading anchors and a table of contents on wide screens), Changelog, Versions (table: version, published, uploader, retracted badge, SHA-256 shortened with copy, link), Install (commands for `dart pub add` and `flutter pub add` with the hosted URL, a pubspec snippet, each with a copy button), Stats (downloads per day for the last 30 days as a bar chart, total downloads, downloads per version, a table alternative for screen readers).
- Sidebar: latest version and date, version selector (dropdown of all versions, prereleases and retracted marked), SDK constraints (Dart, Flutter), platforms, dependencies (links to local packages or pub.dev), uploaders, repository / homepage / issue tracker links from the pubspec, license if present.
- For uploaders and administrators: an "Actions" menu on the header: retract / restore this version, discontinue / continue, manage uploaders, and for administrators delete version, delete package, transfer ownership. Each opens a dialog.

### 3. Login (`/login`)

- Email and password, "Log in" button, generic error for a wrong pair, a rate-limit message with the wait time when the server answers 429, a note about where to get an account (ask an administrator; there is no self sign-up). Redirect back to the page the user came from.

### 4. Account (`/account`)

- Profile: email, display name, role, scopes of the current session.
- Change password: current, new, confirm; the server ends other sessions on success, say so.
- API tokens: table (name, prefix, scopes, created, last used, expires), create form (name, scopes read/publish limited by the role, expiry: 30 days, 90 days, 1 year, never), one-shot secret box after creation with the `dart pub token add <url>` instruction, revoke with confirmation.

### 5. Admin dashboard (`/admin/...`), administrators only

Sidebar sections: Overview, Users, Packages, Audit log, Webhooks, Settings.

- **Overview**: counts (packages, versions, users, webhooks), storage size, last publishes, failed webhook deliveries in the last 24 hours, Mongo and storage health from `/readyz`, link to `/metrics`.
- **Users**: table (email, display name, role, status enabled/disabled, created, last login), search, create user dialog (email, role, display name, optional initial password, or leave empty to let them... note: there is no invite email; the administrator hands over the password), per-row actions: change role, disable/enable, set password, with the rule that the last administrator cannot be demoted or disabled (show the server's 409 message).
- **Packages**: table with search (name, latest, versions count, uploaders, discontinued, downloads), row link to a package admin page with: discontinue form (checkbox + replaced-by), versions table with retract/restore and delete per version, uploaders list with add/remove, transfer ownership, delete package. These reuse the dialogs from the package page.
- **Audit log**: filters (action select, actor, package, from date, to date), table (time, action, actor with credential kind, package/version or user/token target, IP, details expandable as JSON), pagination, link from each row to the package or user. A retention note from settings.
- **Webhooks**: list (URL, events as chips, enabled toggle, deliveries summary: delivered / pending / failed), create dialog (URL, events checkboxes, description), webhook page with edit form (URL, events, description, enabled), rotate secret with confirmation and the one-shot box, delete, deliveries table (time, event, attempt, status, response code, duration, error, redeliver button) and a payload preview with the signature header explained.
- **Settings**: read-only effective configuration grouped by section (server, mongo, storage, upstream, auth, publish, audit, webhooks, metrics, logging), secrets shown as redacted, with a hint which environment variable overrides each key.

### 6. Error pages

403 (with "log in as an administrator"), 404 (with search), 500 (with the request id if the server gives one), offline / API unreachable banner.

## Data shapes to design with

- Package names: `my_company_core`, `flutter_bloc_extensions`, up to 64 characters, snake_case.
- Versions: `1.4.0`, `2.0.0-beta.3`, `1.0.0+5`.
- Descriptions: one sentence, up to about 200 characters, sometimes empty.
- Emails as user identifiers: `jane.doe@company.example`.
- Hashes: 64 hex characters, shown as the first 12 with a copy button.
- Dates: ISO 8601 from the API; show relative ("3 days ago") with the absolute date in a tooltip and in tables.
- Download counts from 0 to millions; format with thin spaces or locale grouping.

## Deliverables

1. Design tokens (colours for light and dark, type scale, spacing, radii, shadows) as CSS variables matching the shadcn/ui theme format.
2. The component set: header, sidebar, search box, package row, badges, tabs, tables with sorting and pagination, forms, dialogs, toasts, one-shot secret box, code block with copy, bar chart, skeletons, empty and error states.
3. Screens 1 to 6 at 1440 px and 390 px, light and dark.
4. A short rationale for the information architecture and anything you changed from this brief.

Export as React + Tailwind components that fit a Vite project using shadcn/ui, with no inline `style` attributes and no external font or icon origins (use Lucide icons, bundled).
