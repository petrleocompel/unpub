import { LogIn, LogOut, Shield, User } from 'lucide-react'
import { Link, NavLink, useLocation, useNavigate } from 'react-router'
import { errorMessage } from '@/api/client'
import { useLogout } from '@/api/queries'
import { useSession } from '@/auth/session'
import { RoleBadge } from '@/components/badges'
import { Button, buttonVariants } from '@/components/ui/button'
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu'
import { toast } from '@/lib/toast'
import { cn } from '@/lib/utils'
import { SearchBox } from './search-box'
import { ThemeToggle } from './theme-toggle'

export function Wordmark() {
  return (
    <Link
      to="/"
      className="flex items-center gap-2 rounded-md font-mono text-lg font-semibold tracking-tight"
      aria-label="unpub home"
    >
      <span
        aria-hidden
        className="grid size-7 place-items-center rounded-md bg-primary text-sm text-primary-foreground"
      >
        u
      </span>
      <span aria-hidden>unpub</span>
    </Link>
  )
}

export function Header() {
  const { me, isAdmin, config } = useSession()
  const location = useLocation()
  const navigate = useNavigate()
  const logout = useLogout()
  const next = `${location.pathname}${location.search}`
  // A private registry shows anonymous visitors the login only.
  const locked = config.readAccess === 'authenticated' && !me

  return (
    <header className="sticky top-0 z-40 border-b bg-background/95 backdrop-blur supports-[backdrop-filter]:bg-background/80">
      <div className="mx-auto flex h-14 max-w-7xl items-center gap-3 px-4 sm:gap-6">
        <Wordmark />
        {!locked && (
          <nav aria-label="Main" className="hidden sm:block">
            <NavLink
              to="/packages"
              className={({ isActive }) =>
                cn(
                  'rounded-md px-2 py-1 text-sm font-medium text-muted-foreground hover:text-foreground',
                  isActive && 'text-foreground',
                )
              }
            >
              Packages
            </NavLink>
          </nav>
        )}
        {!locked && <SearchBox className="max-w-md flex-1" />}
        <div className="ml-auto flex items-center gap-1">
          <ThemeToggle />
          {me ? (
            <DropdownMenu modal={false}>
              <DropdownMenuTrigger asChild>
                <Button variant="ghost" size="sm" aria-label={`Account menu for ${me.user.email}`}>
                  <User aria-hidden />
                  <span className="hidden max-w-48 truncate md:inline">{me.user.email}</span>
                </Button>
              </DropdownMenuTrigger>
              <DropdownMenuContent align="end" className="w-64">
                <DropdownMenuLabel className="grid gap-1.5">
                  <span className="truncate font-normal">{me.user.email}</span>
                  <RoleBadge role={me.user.role} />
                </DropdownMenuLabel>
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
