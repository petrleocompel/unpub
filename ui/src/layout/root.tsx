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
import { Footer } from './footer'
import { Header } from './header'
import { OfflineBanner } from './offline-banner'

/** The page while the config and the session load. */
export function ShellSkeleton() {
  return (
    <div aria-busy="true" className="min-h-screen">
      <span className="sr-only">Loading unpub…</span>
      <div className="flex h-14 items-center gap-6 border-b px-4">
        <Skeleton className="h-7 w-24" />
        <Skeleton className="h-9 max-w-md flex-1" />
      </div>
      <div className="mx-auto grid max-w-7xl gap-4 p-4">
        <Skeleton className="h-8 w-1/3" />
        <Skeleton className="h-24 w-full" />
        <Skeleton className="h-24 w-full" />
      </div>
    </div>
  )
}

export function PageSkeleton() {
  return (
    <div aria-busy="true" className="grid gap-4">
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

/** Loads the config and the session, then lays out every page. */
export function Root() {
  const config = useQuery(configQuery)
  const me = useQuery(meQuery)
  const location = useLocation()
  useUnauthorizedRedirect()

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
        <Header />
        <OfflineBanner />
        <div className="flex-1">
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

/** A page container: the main landmark with the usual width. */
export function Page({ children, wide = false }: { children: React.ReactNode; wide?: boolean }) {
  return (
    <main
      id="main"
      tabIndex={-1}
      className={`mx-auto w-full px-4 py-6 outline-none ${wide ? 'max-w-7xl' : 'max-w-5xl'}`}
    >
      {children}
    </main>
  )
}
