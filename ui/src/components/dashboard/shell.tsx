import { createContext, useContext, useRef, useState, type ReactNode } from 'react'
import { ExternalLink, Menu, type LucideIcon } from 'lucide-react'
import { NavLink, useNavigate } from 'react-router'
import { Button } from '@/components/ui/button'
import { Sheet, SheetContent, SheetHeader, SheetTitle, SheetTrigger } from '@/components/ui/sheet'
import { cn } from '@/lib/utils'

/**
 * A section of the dashboard sidebar: a route ([to]), a fragment of the page
 * ([hash], with [current] when it is the one shown) or a link out of the
 * client ([href], drawn after a separator with an external icon).
 */
export type DashboardSection = {
  label: string
  icon: LucideIcon
  to?: string
  end?: boolean
  hash?: string
  current?: boolean
  href?: string
  /** A count of problems drawn as a red pill, such as failed deliveries. */
  count?: number
  countLabel?: string
}

type Shell = { label: string; sections: DashboardSection[] }

const ShellContext = createContext<Shell | null>(null)

const itemClass =
  'flex h-8.5 items-center gap-2.5 rounded-md px-2.5 text-[0.84375rem] font-medium text-muted-foreground outline-none hover:bg-accent hover:text-foreground focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 focus-visible:ring-offset-surface [&>svg]:size-4 [&>svg]:shrink-0'
const currentClass =
  'bg-background text-foreground shadow-xs ring-1 ring-border hover:bg-background [&>svg:first-child]:text-primary'

function Count({ value, label }: { value: number; label?: string }) {
  return (
    <>
      <span
        aria-hidden
        className="ml-auto rounded-full bg-destructive/14 px-1.5 text-[0.6875rem] leading-4.5 font-semibold text-destructive tabular-nums"
      >
        {value}
      </span>
      <span className="sr-only">, {label ?? value}</span>
    </>
  )
}

function SectionNav({
  label,
  sections,
  onPick,
}: {
  label: string
  sections: DashboardSection[]
  onPick?: (section: DashboardSection, event: React.MouseEvent) => void
}) {
  const inner = sections.filter((section) => !section.href)
  const outer = sections.filter((section) => section.href)
  return (
    <nav aria-label={label}>
      <ul className="grid gap-1">
        {inner.map((section) => {
          const { label: text, icon: Icon } = section
          const content = (
            <>
              <Icon aria-hidden />
              {text}
              {!!section.count && <Count value={section.count} label={section.countLabel} />}
            </>
          )
          return (
            <li key={section.to ?? section.hash}>
              {section.to ? (
                <NavLink
                  to={section.to}
                  end={section.end}
                  onClick={(event) => onPick?.(section, event)}
                  className={({ isActive }) => cn(itemClass, isActive && currentClass)}
                >
                  {content}
                </NavLink>
              ) : (
                <a
                  href={`#${section.hash}`}
                  aria-current={section.current ? 'true' : undefined}
                  onClick={(event) => onPick?.(section, event)}
                  className={cn(itemClass, section.current && currentClass)}
                >
                  {content}
                </a>
              )}
            </li>
          )
        })}
        {outer.length > 0 && <li aria-hidden className="mx-2.5 my-2 h-px bg-border" />}
        {outer.map(({ label: text, icon: Icon, href }) => (
          <li key={href}>
            <a href={href} className={itemClass}>
              <Icon aria-hidden />
              {text}
              <ExternalLink aria-hidden className="ml-auto size-3!" />
            </a>
          </li>
        ))}
      </ul>
    </nav>
  )
}

/**
 * The dashboard of Account and Administration: a sidebar of [sections] on
 * wide screens, a "Sections" drawer opened from the page heading on phones,
 * and the main landmark.
 */
export function DashboardShell({
  label,
  sections,
  mainClassName,
  children,
}: {
  label: string
  sections: DashboardSection[]
  mainClassName?: string
  children: ReactNode
}) {
  return (
    <ShellContext.Provider value={{ label, sections }}>
      <div className="grid w-full flex-1 md:grid-cols-[14.5rem_minmax(0,1fr)]">
        <aside className="hidden border-r bg-surface px-3 py-5 md:block">
          <div className="sticky top-20">
            <p className="mb-2 px-2.5 text-[0.6875rem] font-semibold tracking-[0.08em] text-muted-foreground uppercase">
              {label}
            </p>
            <SectionNav label={`${label} sections`} sections={sections} />
          </div>
        </aside>
        <main
          id="main"
          tabIndex={-1}
          className={cn(
            'w-full min-w-0 px-4 pt-4 pb-10 outline-none md:px-8 md:pt-6 md:pb-12',
            mainClassName,
          )}
        >
          {children}
        </main>
      </div>
    </ShellContext.Provider>
  )
}

/** The "Sections" button of the page heading on phones, with its drawer. */
function SectionsDrawer() {
  const shell = useContext(ShellContext)
  const navigate = useNavigate()
  const [open, setOpen] = useState(false)
  const picked = useRef<DashboardSection | null>(null)
  if (!shell) return null
  return (
    <Sheet open={open} onOpenChange={setOpen}>
      <SheetTrigger asChild>
        <Button variant="outline" size="sm" className="md:hidden">
          <Menu aria-hidden />
          Sections
        </Button>
      </SheetTrigger>
      <SheetContent
        side="left"
        className="w-64 bg-surface p-4"
        aria-describedby={undefined}
        onCloseAutoFocus={(event) => {
          const section = picked.current
          picked.current = null
          if (!section) return
          // After a section is picked the focus goes to its page instead.
          event.preventDefault()
          if (section.hash) {
            navigate({ hash: section.hash })
            document.getElementById(section.hash)?.scrollIntoView()
          }
          document.getElementById('main')?.focus({ preventScroll: true })
        }}
      >
        <SheetHeader className="p-0 pb-2">
          <SheetTitle className="px-2.5 text-[0.6875rem] font-semibold tracking-[0.08em] text-muted-foreground uppercase">
            {shell.label}
          </SheetTitle>
        </SheetHeader>
        <SectionNav
          label={`${shell.label} sections`}
          sections={shell.sections}
          onPick={(section, event) => {
            // A fragment is scrolled to once the drawer has let go of the page.
            if (section.hash) event.preventDefault()
            picked.current = section
            setOpen(false)
          }}
        />
      </SheetContent>
    </Sheet>
  )
}

/**
 * The heading of a dashboard page: the title and a line under it, and on the
 * right the [actions] after the "Sections" button of phones. [above] holds a
 * breadcrumb.
 */
export function DashboardHeading({
  title,
  description,
  actions,
  above,
  titleClassName,
  className,
}: {
  title: ReactNode
  description?: ReactNode
  actions?: ReactNode
  above?: ReactNode
  titleClassName?: string
  className?: string
}) {
  return (
    <div className={cn('mb-5 grid gap-2', className)}>
      {above}
      <div className="flex flex-wrap items-end justify-between gap-4">
        <div className="grid min-w-0 gap-1">
          <h1
            className={cn(
              'text-xl leading-7 font-semibold tracking-[-0.015em] md:text-[1.375rem] md:leading-[1.875rem]',
              titleClassName,
            )}
          >
            {title}
          </h1>
          {description && (
            <div className="text-[0.8125rem] text-muted-foreground">{description}</div>
          )}
        </div>
        <div className="flex flex-wrap items-center gap-2 empty:hidden">
          <SectionsDrawer />
          {actions}
        </div>
      </div>
    </div>
  )
}
