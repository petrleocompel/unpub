import { lazy } from 'react'
import type { RouteObject } from 'react-router'
import { RequireAdmin, RequireLogin } from '@/auth/guards'
import { Root } from '@/layout/root'
import { NotFoundPage, RouteErrorPage } from '@/pages/errors'
import { LoginPage } from '@/pages/login'
import { PackagePage } from '@/pages/package'
import { PackageListPage } from '@/pages/package-list'

// Account and administration load on demand: most visits only read packages.
const AccountPage = lazy(() => import('@/pages/account').then((m) => ({ default: m.AccountPage })))
const AdminLayout = lazy(() =>
  import('@/pages/admin/layout').then((m) => ({ default: m.AdminLayout })),
)
const OverviewPage = lazy(() =>
  import('@/pages/admin/overview').then((m) => ({ default: m.OverviewPage })),
)
const UsersPage = lazy(() => import('@/pages/admin/users').then((m) => ({ default: m.UsersPage })))
const AdminPackagesPage = lazy(() =>
  import('@/pages/admin/packages').then((m) => ({ default: m.AdminPackagesPage })),
)
const AdminPackagePage = lazy(() =>
  import('@/pages/admin/packages').then((m) => ({ default: m.AdminPackagePage })),
)
const AuditPage = lazy(() => import('@/pages/admin/audit').then((m) => ({ default: m.AuditPage })))
const WebhooksPage = lazy(() =>
  import('@/pages/admin/webhooks').then((m) => ({ default: m.WebhooksPage })),
)
const WebhookPage = lazy(() =>
  import('@/pages/admin/webhook').then((m) => ({ default: m.WebhookPage })),
)
const SettingsPage = lazy(() =>
  import('@/pages/admin/settings').then((m) => ({ default: m.SettingsPage })),
)

/** The routes, the same paths as the server-rendered pages. */
export const routes: RouteObject[] = [
  {
    element: <Root />,
    errorElement: <RouteErrorPage />,
    children: [
      { index: true, element: <PackageListPage /> },
      { path: 'packages', element: <PackageListPage /> },
      { path: 'packages/:name', element: <PackagePage /> },
      { path: 'packages/:name/stats', element: <PackagePage defaultTab="stats" /> },
      { path: 'packages/:name/versions/:version', element: <PackagePage /> },
      { path: 'login', element: <LoginPage /> },
      {
        path: 'account',
        element: (
          <RequireLogin>
            <AccountPage />
          </RequireLogin>
        ),
      },
      {
        path: 'admin',
        element: (
          <RequireAdmin>
            <AdminLayout />
          </RequireAdmin>
        ),
        children: [
          { index: true, element: <OverviewPage /> },
          { path: 'users', element: <UsersPage /> },
          { path: 'packages', element: <AdminPackagesPage /> },
          { path: 'packages/:name', element: <AdminPackagePage /> },
          { path: 'audit', element: <AuditPage /> },
          { path: 'webhooks', element: <WebhooksPage /> },
          { path: 'webhooks/:id', element: <WebhookPage /> },
          { path: 'settings', element: <SettingsPage /> },
        ],
      },
      { path: '*', element: <NotFoundPage /> },
    ],
  },
]
