import {
  Activity,
  Boxes,
  LayoutDashboard,
  ScrollText,
  Settings,
  Users,
  Webhook,
} from 'lucide-react'
import { Outlet } from 'react-router'
import { useOverview } from '@/api/queries'
import { useSession } from '@/auth/session'
import {
  DashboardHeading,
  DashboardShell,
  type DashboardSection,
} from '@/components/dashboard/shell'

/** The administration: the dashboard shell with its sections. */
export function AdminLayout() {
  const { config } = useSession()
  // The same query as the overview, so the count costs one request.
  const overview = useOverview()
  const failed = overview.data?.failedDeliveriesLast24h ?? 0
  const sections: DashboardSection[] = [
    { to: '/admin', label: 'Overview', icon: LayoutDashboard, end: true },
    { to: '/admin/users', label: 'Users', icon: Users },
    { to: '/admin/packages', label: 'Packages', icon: Boxes },
    { to: '/admin/audit', label: 'Audit log', icon: ScrollText },
    ...(config.features.webhooks
      ? [
          {
            to: '/admin/webhooks',
            label: 'Webhooks',
            icon: Webhook,
            count: failed,
            countLabel: `${failed} failed ${failed === 1 ? 'delivery' : 'deliveries'} in 24 h`,
          },
        ]
      : []),
    { to: '/admin/settings', label: 'Settings', icon: Settings },
    ...(config.features.metrics ? [{ href: '/metrics', label: 'Metrics', icon: Activity }] : []),
  ]
  return (
    <DashboardShell label="Administration" sections={sections}>
      <Outlet />
    </DashboardShell>
  )
}

/** The heading of an administration page. */
export const AdminHeading = DashboardHeading
