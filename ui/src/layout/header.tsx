import { ChevronDown, LogIn, LogOut, Package, Shield, User } from 'lucide-react'
import { Link, NavLink, useLocation, useNavigate } from 'react-router'
import { errorMessage } from '@/api/client'
import { useLogout } from '@/api/queries'
import { useSession } from '@/auth/session'
import { Initials } from '@/components/avatar'
import { RoleBadge } from '@/components/badges'
import { buttonVariants } from '@/components/ui/button'
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu'
import { toast } from '@/lib/toast'
import { cn } from '@/lib/utils'
import { SearchBox } from './search-box'
import { ThemeToggle } from './theme-toggle'

/** The mark: a package dropping into the "u". Colours follow the theme. */
export function Mark({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" aria-hidden className={cn('size-7 shrink-0', className)}>
      <rect width="24" height="24" rx="6" className="fill-primary" />
      <path
        d="M7.5 7.5v5a4.5 4.5 0 0 0 9 0v-5"
        fill="none"
        strokeWidth="2.4"
        strokeLinecap="round"
        className="stroke-primary-foreground"
      />
      <rect x="10.25" y="9" width="3.5" height="3.5" rx="0.8" className="fill-primary-foreground" />
    </svg>
  )
}

export function Wordmark() {
  return (
    <Link
      to="/"
      className="flex shrink-0 items-center gap-2 rounded-md text-[1.1875rem] font-[650] tracking-[-0.03em] text-foreground"
      aria-label="unpub home"
    >
      <Mark />
      <span aria-hidden>unpub</span>
    </Link>
  )
}

/**
 * The header of docs/design (board 01): mark, navigation, search, theme and
 * the user. Below sm the search takes a row of its own under the rest.
 */
export function Header() {
  const { me, isAdmin, config } = useSession()
  const location = useLocation()
  const navigate = useNavigate()
  const logout = useLogout()
  const next = `${location.pathname}${location.search}`
  // A private registry shows anonymous visitors the login only.
  const locked = config.readAccess === 'authenticated' && !me

  return (
    <header className="sticky top-0 z-40 border-b bg-background/92 backdrop-blur supports-[backdrop-filter]:bg-background/85">
      <div className="mx-auto flex max-w-7xl flex-wrap items-center gap-x-2 gap-y-2.5 px-4 py-2.5 sm:h-15 sm:flex-nowrap sm:gap-6 sm:px-6 sm:py-0">
        <Wordmark />
        {!locked && (
          <nav aria-label="Main" className="shrink-0">
            <NavLink
              to="/packages"
              className={({ isActive }) =>
                cn(
                  'flex h-8 items-center gap-1.5 rounded-md px-2 text-sm font-medium text-muted-foreground hover:bg-accent hover:text-foreground sm:px-2.5',
                  isActive && 'bg-accent text-foreground',
                )
              }
            >
              {/* An icon below sm, where the search needs the room. */}
              <Package aria-hidden className="size-4 sm:hidden" />
              <span className="sr-only sm:not-sr-only">Packages</span>
            </NavLink>
          </nav>
        )}
        {!locked && (
          <SearchBox className="order-last basis-full sm:order-none sm:max-w-[520px] sm:min-w-0 sm:flex-1 sm:basis-auto" />
        )}
        <div className="ml-auto flex items-center gap-1">
          <ThemeToggle />
          {me ? (
            <DropdownMenu modal={false}>
              <DropdownMenuTrigger asChild>
                <button
                  type="button"
                  aria-label={`Account menu for ${me.user.email}`}
                  className="inline-flex h-9 items-center gap-2 rounded-lg pr-1 pl-1 text-[0.8125rem] text-foreground hover:bg-accent md:pr-2"
                >
                  <Initials email={me.user.email} size="md" />
                  <span className="hidden max-w-56 truncate md:inline">{me.user.email}</span>
                  <ChevronDown
                    aria-hidden
                    className="hidden size-3.5 text-muted-foreground md:block"
                  />
                </button>
              </DropdownMenuTrigger>
              <DropdownMenuContent align="end" className="w-64">
                <div className="grid justify-items-start gap-1.5 px-2.5 pt-2 pb-2.5">
                  <span className="w-full truncate text-[0.8125rem]">{me.user.email}</span>
                  <RoleBadge role={me.user.role} />
                </div>
                <DropdownMenuSeparator />
                <DropdownMenuItem asChild>
                  <Link to="/account">
                    <User aria-hidden />
                    Account
                  </Link>
                </DropdownMenuItem>
                {isAdmin && (
                  <DropdownMenuItem asChild>
                    <Link to="/admin">
                      <Shield aria-hidden />
                      Admin
                    </Link>
                  </DropdownMenuItem>
                )}
                <DropdownMenuSeparator />
                <DropdownMenuItem
                  onSelect={() =>
                    logout.mutate(undefined, {
                      onSuccess: () => {
                        toast.success('Logged out')
                        navigate(config.readAccess === 'authenticated' ? '/login' : '/')
                      },
                      onError: (error) => toast.error('Logging out failed', errorMessage(error)),
                    })
                  }
                >
                  <LogOut aria-hidden />
                  Log out
                </DropdownMenuItem>
              </DropdownMenuContent>
            </DropdownMenu>
          ) : (
            config.accounts &&
            location.pathname !== '/login' && (
              <Link
                to={`/login?next=${encodeURIComponent(next)}`}
                className={buttonVariants({ variant: 'outline', size: 'sm' })}
              >
                <LogIn aria-hidden />
                Log in
              </Link>
            )
          )}
        </div>
      </div>
    </header>
  )
}
