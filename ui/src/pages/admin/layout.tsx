import { useRef, useState } from 'react'
import {
  Activity,
  Boxes,
  LayoutDashboard,
  Menu,
  ScrollText,
  Settings,
  Users,
  Webhook,
} from 'lucide-react'
import { NavLink, Outlet } from 'react-router'
import { useSession } from '@/auth/session'
import { Button } from '@/components/ui/button'
import { Sheet, SheetContent, SheetHeader, SheetTitle, SheetTrigger } from '@/components/ui/sheet'
import { cn } from '@/lib/utils'

const sections = [
  { to: '/admin', label: 'Overview', icon: LayoutDashboard, end: true },
  { to: '/admin/users', label: 'Users', icon: Users },
  { to: '/admin/packages', label: 'Packages', icon: Boxes },
  { to: '/admin/audit', label: 'Audit log', icon: ScrollText },
  { to: '/admin/webhooks', label: 'Webhooks', icon: Webhook, feature: 'webhooks' as const },
  { to: '/admin/settings', label: 'Settings', icon: Settings },
]

function AdminNav({ onNavigate }: { onNavigate?: () => void }) {
  const { config } = useSession()
  return (
    <nav aria-label="Administration">
      <ul className="grid gap-1">
        {sections
          .filter((section) => !section.feature || config.features[section.feature])
          .map(({ to, label, icon: Icon, end }) => (
            <li key={to}>
              <NavLink
                to={to}
                end={end}
                onClick={onNavigate}
                className={({ isActive }) =>
                  cn(
                    'flex items-center gap-2 rounded-md px-3 py-2 text-sm font-medium text-muted-foreground hover:bg-accent hover:text-foreground',
                    isActive && 'bg-accent text-foreground',
                  )
                }
              >
                <Icon aria-hidden className="size-4" />
                {label}
              </NavLink>
            </li>
          ))}
        {config.features.metrics && (
          <li>
            <a
              href="/metrics"
              className="flex items-center gap-2 rounded-md px-3 py-2 text-sm font-medium text-muted-foreground hover:bg-accent hover:text-foreground"
            >
              <Activity aria-hidden className="size-4" />
              Metrics
            </a>
          </li>
        )}
      </ul>
    </nav>
  )
}

/** The dashboard: a sidebar of sections, a drawer on small screens. */
export function AdminLayout() {
  const [open, setOpen] = useState(false)
  const picked = useRef(false)
  return (
    <div className="mx-auto grid w-full max-w-7xl gap-6 px-4 py-6 md:grid-cols-[13rem_minmax(0,1fr)]">
      <div className="md:hidden">
        <Sheet open={open} onOpenChange={setOpen}>
          <SheetTrigger asChild>
            <Button variant="outline" size="sm">
              <Menu aria-hidden />
              Admin sections
            </Button>
          </SheetTrigger>
          <SheetContent
            side="left"
            className="w-64 p-4"
            onCloseAutoFocus={(event) => {
              // After a section is picked the focus goes to its page instead.
              if (picked.current) {
                event.preventDefault()
                document.getElementById('main')?.focus({ preventScroll: true })
              }
              picked.current = false
            }}
          >
            <SheetHeader className="p-0 pb-4">
              <SheetTitle>Administration</SheetTitle>
            </SheetHeader>
            <AdminNav
              onNavigate={() => {
                picked.current = true
                setOpen(false)
              }}
            />
          </SheetContent>
        </Sheet>
      </div>
      <aside className="hidden md:block">
        <div className="sticky top-20">
          <p className="mb-2 px-3 text-xs font-semibold tracking-wide text-muted-foreground uppercase">
            Admin
          </p>
          <AdminNav />
        </div>
      </aside>
      <main id="main" tabIndex={-1} className="min-w-0 outline-none">
        <Outlet />
      </main>
    </div>
  )
}

export function AdminHeading({
  title,
  description,
  actions,
}: {
  title: string
  description?: React.ReactNode
  actions?: React.ReactNode
}) {
  return (
    <div className="mb-6 flex flex-wrap items-end justify-between gap-4">
      <div className="grid gap-1">
        <h1 className="text-2xl font-semibold">{title}</h1>
        {description && <p className="text-sm text-muted-foreground">{description}</p>}
      </div>
      {actions}
    </div>
  )
}
