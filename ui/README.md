# unpub web client

The single-page client of unpub: React 19, TypeScript, Vite, Tailwind CSS 4, [shadcn/ui](https://ui.shadcn.com) (Radix) components, TanStack Query and React Router. It talks only to `/webapi/*` and `/api/packages/*` of the server, with the session cookie and the `X-CSRF-Token` header, and the Dart server serves its build. See "Web client" in the [README](../README.md#web-client) for how the server serves it.

## Development

Use Node 22 (`.nvmrc`) and npm.

```sh
# A server on http://localhost:4000, with MongoDB, from the repository root:
docker compose -f docker-compose.dev.yml up -d mongo
(cd unpub && dart run bin/unpub.dart serve --config ../unpub.yaml)

# The client, with hot reload, on http://localhost:5173:
cd ui
npm ci
npm run dev
```

The Vite development server proxies `/webapi`, `/api`, `/badge`, `/static`, `/classic`, the probes, `/metrics` and the archives (`/packages/<name>/versions/<version>.tar.gz`) to `http://localhost:4000`. Set `UNPUB_DEV_SERVER` to use another server. Every other path is a route of the client. Log in with an account of that server; set `auth.admin.email` and `auth.admin.password` in its configuration to get the first administrator.

| Script              | What it does                                                                                           |
| ------------------- | ------------------------------------------------------------------------------------------------------ |
| `npm run dev`       | The development server with the proxy.                                                                 |
| `npm run build`     | Type-checks and builds into `dist/`, which the server serves as `ui.assetsDir`.                        |
| `npm run preview`   | Serves `dist/` without the server, for a quick look. The API is not proxied.                           |
| `npm run lint`      | ESLint (typescript-eslint, react-hooks, jsx-a11y) and Prettier. `npm run format` fixes the formatting. |
| `npm run typecheck` | TypeScript, strict.                                                                                    |
| `npm test`          | Vitest with Testing Library and MSW, in watch mode; `npm test -- --run` once.                          |
| `npm run test:e2e`  | The Playwright smoke run against the real server, see below.                                           |
| `npm run api:types` | Regenerates `src/api/schema.d.ts` from `../docs/openapi.yaml`.                                         |
| `npm run api:check` | Fails when `src/api/schema.d.ts` is out of date. CI runs it.                                           |

## The API types

`docs/openapi.yaml` is the contract. After changing it, run `npm run api:types` and commit `src/api/schema.d.ts`. `src/api/client.ts` is the typed `openapi-fetch` client: it adds the CSRF token to every request that is not GET, HEAD or OPTIONS, turns error bodies `{error: {code, message}}` into `ApiError`, and reports a 401 to the app, which sends the user to `/login?next=...`. `src/api/queries.ts` has a TanStack Query hook per route.

## Layout

| Path              | What is there                                                                                                                                 |
| ----------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| `src/routes.tsx`  | The routes, the same paths as the server-rendered pages. Account and administration load on demand.                                           |
| `src/layout/`     | The shell: header with search, user menu and theme toggle, footer, offline banner. Loads `/webapi/config` and `/webapi/me` first.             |
| `src/pages/`      | One file per page, `src/pages/admin/` for the dashboard.                                                                                      |
| `src/packages/`   | The package dialogs (retract, discontinue, uploaders, transfer, delete) shared by the package page and the admin page, and the markdown view. |
| `src/components/` | Shared components. `src/components/ui/` are shadcn/ui components added with `npx shadcn@latest add <name>`.                                   |
| `src/lib/`        | Formatting, theme, toasts, the base path.                                                                                                     |
| `src/test/`       | Fixtures, MSW handlers, the render helper and the page tests.                                                                                 |
| `e2e/`            | The Playwright smoke test and its fixture package.                                                                                            |

## Content-Security-Policy

The server sends `index.html` with `script-src 'self'; style-src 'self'` and no `unsafe-inline`, so:

- `index.html` has no inline script or style, and Vite emits none (`base: './'`, every asset a file).
- No `style` attribute in markup. Styles set from JavaScript through the CSSOM, as React's `style` prop and Radix positioning do, are allowed.
- No `<style>` elements at runtime. That rules out sonner (toasts come from Radix Toast, `src/components/toaster.tsx`) and Radix Select (`src/components/native-select.tsx` styles a native `<select>`), and `react-style-singleton`, the scroll lock of Radix dialogs, is replaced through a Vite alias by `src/lib/style-singleton.ts`, which adopts a constructed stylesheet.
- No third-party origin: fonts are system font stacks, icons are Lucide components in the bundle. A bundled font goes under `src/` and is referenced from CSS.
- Charts are SVG with attributes and classes (`src/components/bar-chart.tsx`).

The end-to-end test fails on any console error, which is where the browser reports violations.

## Restyling

Every colour, radius and font is a CSS variable in `src/index.css`, in the shadcn/ui theme format (`--background`, `--primary`, `--radius`, `--font-sans`, ... for `:root` and `.dark`), mapped to Tailwind with `@theme inline`. Components use the Tailwind classes of those tokens (`bg-primary`, `text-muted-foreground`) and no raw colours. A new design means new values for these variables, and new shadcn/ui components through its CLI; dark mode is the `dark` class on `<html>`, set from the system or the toggle and kept in `localStorage` under `unpub-theme`.

## End-to-end test

`npm run test:e2e` runs `e2e/run.sh`: it builds the client, starts MongoDB in Docker (or uses `UNPUB_E2E_MONGO_URI`, as CI does), starts the Dart server from `../unpub` with the build as `ui.assetsDir` on port 4123 (`UNPUB_E2E_PORT`), publishes `e2e/fixtures/e2e_demo` through the pub API, runs Playwright in Chromium and cleans up. It needs Docker, the Dart SDK and `npx playwright install chromium` once. `UNPUB_E2E_SKIP_BUILD=1` reuses `dist/`; other arguments go to `playwright test`, such as `--headed` or `--debug`.
