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
                    'flex h-8.5 items-center gap-2.5 rounded-md px-2.5 text-[0.84375rem] font-medium text-muted-foreground hover:bg-accent hover:text-foreground [&>svg]:size-4',
                    isActive &&
                      'bg-background text-foreground shadow-xs ring-1 ring-border [&>svg]:text-primary',
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
              className="flex h-8.5 items-center gap-2.5 rounded-md px-2.5 text-[0.84375rem] font-medium text-muted-foreground hover:bg-accent hover:text-foreground"
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
    <div className="grid w-full flex-1 md:grid-cols-[14.5rem_minmax(0,1fr)]">
      <div className="px-4 pt-4 md:hidden">
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
      <aside className="hidden border-r bg-surface px-3 py-5 md:block">
        <div className="sticky top-20">
          <p className="mb-2 px-2.5 text-[0.6875rem] font-semibold tracking-[0.08em] text-muted-foreground uppercase">
            Administration
          </p>
          <AdminNav />
        </div>
      </aside>
      <main id="main" tabIndex={-1} className="min-w-0 px-4 py-4 outline-none md:px-8 md:py-6">
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
    <div className="mb-5 flex flex-wrap items-end justify-between gap-4">
      <div className="grid gap-1">
        <h1 className="text-[1.375rem] leading-[1.875rem] font-semibold tracking-tight">{title}</h1>
        {description && <p className="text-sm text-muted-foreground">{description}</p>}
      </div>
      {actions}
    </div>
  )
}
