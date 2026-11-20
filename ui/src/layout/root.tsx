import { Suspense, useEffect, useRef } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { Navigate, Outlet, useLocation, useNavigate } from 'react-router'
import { setUnauthorizedHandler } from '@/api/client'
import { configQuery, meQuery } from '@/api/queries'
import { ErrorState } from '@/components/states'
import { Toaster } from '@/components/toaster'
import { Skeleton } from '@/components/ui/skeleton'
import { TooltipProvider } from '@/components/ui/tooltip'
import { toast } from '@/lib/toast'
import { cn } from '@/lib/utils'
import { Footer } from './footer'
import { Header } from './header'
import { OfflineBanner } from './offline-banner'

/** The page while the config and the session load. */
export function ShellSkeleton() {
  return (
    <div aria-busy="true" aria-live="polite" className="min-h-screen">
      <span className="sr-only">Loading unpub…</span>
      <div className="mx-auto flex h-15 max-w-7xl items-center gap-6 border-b px-4 sm:px-6">
        <Skeleton className="h-7 w-24" />
        <Skeleton className="h-9.5 max-w-[520px] flex-1" />
      </div>
      <div className="mx-auto grid max-w-7xl gap-4 px-4 py-8 sm:px-6">
        <Skeleton className="h-8 w-1/3" />
        <Skeleton className="h-24 w-full" />
        <Skeleton className="h-24 w-full" />
      </div>
    </div>
  )
}

export function PageSkeleton() {
  return (
    <div aria-busy="true" aria-live="polite" className="grid gap-4">
      <span className="sr-only">Loading…</span>
      <Skeleton className="h-8 w-1/3" />
      <Skeleton className="h-40 w-full" />
    </div>
  )
}

function useUnauthorizedRedirect() {
  const client = useQueryClient()
  const navigate = useNavigate()
  const location = useLocation()
  const current = useRef(location)
  useEffect(() => {
    current.current = location
  })

  useEffect(() => {
    setUnauthorizedHandler(() => {
      const { pathname, search } = current.current
      client.setQueryData(['me'], null)
      if (pathname === '/login') return
      toast.info('Please log in', 'Your session has ended or this needs an account.')
      navigate(`/login?next=${encodeURIComponent(`${pathname}${search}`)}`, { replace: true })
    })
    return () => setUnauthorizedHandler(() => {})
  }, [client, navigate])
}

/** How long a new page may take to render its main landmark. */
const focusWindowMs = 5000

/**
 * Moves the focus to the main landmark of a new page, as a full load would
 * reset it, without scrolling. Changes of the query alone (filters, tabs,
 * search) keep the focus where it is. A page that is still loading gets the
 * focus once its main renders, also when the main is replaced on load.
 */
export function useFocusOnNavigation() {
  const { pathname } = useLocation()
  const previous = useRef(pathname)
  useEffect(() => {
    if (previous.current === pathname) return
    previous.current = pathname
    const focus = (main: HTMLElement) => main.focus({ preventScroll: true })
    let main = document.getElementById('main')
    // Not rendered yet: focus it when it is.
    let pending = !main
    if (main) focus(main)
    const focusMain = () => {
      main = document.getElementById('main')
      if (!main || main === document.activeElement) return
      const active = document.activeElement
      const lost = !active || active === document.body || !active.isConnected
      if (pending || lost) focus(main)
      pending = false
    }
    const observer = new MutationObserver(focusMain)
    observer.observe(document.body, { childList: true, subtree: true })
    const stop = window.setTimeout(() => observer.disconnect(), focusWindowMs)
    return () => {
      observer.disconnect()
      window.clearTimeout(stop)
    }
  }, [pathname])
}

/** Loads the config and the session, then lays out every page. */
export function Root() {
  const config = useQuery(configQuery)
  const me = useQuery(meQuery)
  const location = useLocation()
  useUnauthorizedRedirect()
  useFocusOnNavigation()

  if (config.isPending || me.isPending) return <ShellSkeleton />
  if (config.isError || me.isError) {
    return (
      <main className="mx-auto max-w-xl p-8">
        <ErrorState
          title="unpub cannot be reached"
          error={config.error ?? me.error}
          onRetry={() => {
            void config.refetch()
            void me.refetch()
          }}
        />
      </main>
    )
  }

  // A private registry shows anonymous visitors nothing but the login.
  if (config.data.readAccess === 'authenticated' && !me.data && location.pathname !== '/login') {
    const next = `${location.pathname}${location.search}`
    return (
      <Navigate to={next === '/' ? '/login' : `/login?next=${encodeURIComponent(next)}`} replace />
    )
  }

  return (
    <TooltipProvider delayDuration={300}>
      <div className="flex min-h-screen flex-col">
        <a
          href="#main"
          className="sr-only z-50 rounded-md bg-background px-3 py-2 focus:not-sr-only focus:absolute focus:top-2 focus:left-2"
        >
          Skip to content
        </a>
        {/* Above the header, as board 02 draws it. */}
        <OfflineBanner />
        <Header />
        <div className="flex flex-1 flex-col">
          <Suspense
            fallback={
              <div className="mx-auto max-w-7xl p-4">
                <PageSkeleton />
              </div>
            }
          >
            <Outlet />
          </Suspense>
        </div>
        <Footer />
      </div>
      <Toaster />
    </TooltipProvider>
  )
}

/**
 * A page container: the main landmark. [wide] is the 1280 px container of
 * the public pages, the default a narrower column; [full] leaves the width
 * and the padding to the page, for bands that span the window.
 */
export function Page({
  children,
  wide = false,
  full = false,
  className,
}: {
  children: React.ReactNode
  wide?: boolean
  full?: boolean
  className?: string
}) {
  return (
    <main
      id="main"
      tabIndex={-1}
      className={cn(
        'w-full outline-none',
        !full && 'mx-auto px-4 pt-5 pb-10 sm:px-6 sm:pt-8 sm:pb-14',
        !full && (wide ? 'max-w-7xl' : 'max-w-5xl'),
        full && 'flex flex-1 flex-col',
        className,
      )}
    >
      {children}
    </main>
  )
}
