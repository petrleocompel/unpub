import { useState, type ReactNode } from 'react'
import { useQuery } from '@tanstack/react-query'
import { ChevronLeft, LogIn, Package, RotateCw, Search } from 'lucide-react'
import { Link, useLocation, useNavigate, useRouteError } from 'react-router'
import { errorMessage } from '@/api/client'
import { packagesQuery } from '@/api/queries'
import { useSession } from '@/auth/session'
import { Button, buttonVariants } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Page } from '@/layout/root'
import { basePath } from '@/lib/base'
import { useTitle } from '@/lib/use-title'
import { cn } from '@/lib/utils'

/** The big status code of the error pages (boards 02 and 09); decorative. */
function ErrorCode({ code }: { code: number }) {
  return (
    <p
      aria-hidden
      className="font-mono text-[3.5rem] leading-none font-semibold tracking-[-0.04em] text-[color-mix(in_oklab,var(--primary)_70%,var(--foreground))] sm:text-7xl"
    >
      {code}
    </p>
  )
}

function ErrorLayout({
  code,
  title,
  documentTitle,
  children,
}: {
  code: number
  title: ReactNode
  documentTitle: string
  children: ReactNode
}) {
  useTitle(documentTitle)
  return (
    <Page className="grid flex-1 place-items-center sm:pt-20 sm:pb-20">
      <section className="grid w-full max-w-[560px] justify-items-center gap-5 text-center">
        <ErrorCode code={code} />
        <div className="grid justify-items-center gap-2">
          <h1 className="text-2xl font-semibold tracking-[-0.015em]">{title}</h1>
        </div>
        {children}
      </section>
    </Page>
  )
}

/** Edits needed to turn [a] into [b]. */
export function editDistance(a: string, b: string) {
  let previous = Array.from({ length: b.length + 1 }, (_, index) => index)
  for (let i = 1; i <= a.length; i++) {
    const current = [i]
    for (let j = 1; j <= b.length; j++) {
      current[j] = Math.min(
        previous[j]! + 1,
        current[j - 1]! + 1,
        previous[j - 1]! + (a[i - 1] === b[j - 1] ? 0 : 1),
      )
    }
    previous = current
  }
  return previous[b.length]!
}

/**
 * The closest of [names] to [name], when it is close enough to be a
 * likely meant name: at most half of the longer name differs.
 */
export function closestName(name: string, names: string[]) {
  const wanted = name.toLowerCase()
  let best: { name: string; distance: number } | null = null
  for (const candidate of names) {
    if (candidate.toLowerCase() === wanted) continue
    const distance = editDistance(wanted, candidate.toLowerCase())
    if (!best || distance < best.distance) best = { name: candidate, distance }
  }
  if (!best) return null
  const longer = Math.max(wanted.length, best.name.length)
  return best.distance <= Math.max(2, Math.ceil(longer / 2)) ? best.name : null
}

/**
 * A package that may have been meant: one search of the list with the
 * missing name, the closest name of the first five results.
 */
function useSuggestion(name: string | undefined) {
  const { config, me } = useSession()
  const enabled = !!name && (config.readAccess !== 'authenticated' || !!me)
  const result = useQuery({
    ...packagesQuery({ q: name, size: 5 }),
    enabled,
    retry: false,
    placeholderData: undefined,
  })
  return enabled && result.data
    ? closestName(
        name,
        result.data.items.map((item) => item.name),
      )
    : null
}

/**
 * Board 09: the status, what is missing, a likely meant package and a
 * search. [name] is the missing package, which the search starts from;
 * [upstream] is where a redirecting server would have sent the client.
 */
export function NotFoundPage({
  what = 'page',
  name,
  upstream,
}: {
  what?: string
  name?: string
  upstream?: { host: string; href: string }
}) {
  const navigate = useNavigate()
  const isPackage = what === 'package' && !!name
  const [query, setQuery] = useState(isPackage ? name : '')
  const suggestion = useSuggestion(isPackage ? name : undefined)
  return (
    <ErrorLayout
      code={404}
      documentTitle={`This ${what} does not exist`}
      title={
        isPackage ? (
          <>
            No package called <span className="font-mono break-all">{name}</span>
          </>
        ) : (
          `This ${what} does not exist`
        )
      }
    >
      <p className="-mt-3 text-[0.9375rem] leading-6 text-muted-foreground">
        {isPackage
          ? 'It may have been deleted, or the name is misspelled.'
          : 'Check the address, or search for what you are looking for.'}
        {suggestion && (
          <>
            {' '}
            Did you mean{' '}
            <Link
              to={`/packages/${encodeURIComponent(suggestion)}`}
              className="font-mono font-medium text-primary hover:underline hover:underline-offset-3"
            >
              {suggestion}
            </Link>
            ?
          </>
        )}
        {upstream && (
          <>
            {' '}
            It may be on{' '}
            <a
              className="font-medium text-primary hover:underline hover:underline-offset-3"
              href={upstream.href}
            >
              {upstream.host}
            </a>
            .
          </>
        )}
      </p>
      <form
        role="search"
        className="relative w-full max-w-[480px]"
        onSubmit={(event) => {
          event.preventDefault()
          navigate(`/packages${query.trim() ? `?q=${encodeURIComponent(query.trim())}` : ''}`)
        }}
      >
        <label htmlFor="not-found-search" className="sr-only">
          Search packages
        </label>
        <Search
          aria-hidden
          className="pointer-events-none absolute top-1/2 left-[15px] size-4.5 -translate-y-1/2 text-muted-foreground"
        />
        <Input
          id="not-found-search"
          type="search"
          value={query}
          spellCheck={false}
          onChange={(event) => setQuery(event.target.value)}
          placeholder="Search packages"
          className="h-12 rounded-[10px] pl-11 text-base md:text-base"
        />
      </form>
      <div className="flex flex-wrap justify-center gap-3">
        <Link to="/packages" className={buttonVariants()}>
          <Package aria-hidden />
          All packages
        </Link>
        <Button variant="outline" onClick={() => navigate(-1)}>
          <ChevronLeft aria-hidden />
          Back
        </Button>
      </div>
    </ErrorLayout>
  )
}

export function ForbiddenPage() {
  const location = useLocation()
  const { me } = useSession()
  const next = encodeURIComponent(`${location.pathname}${location.search}`)
  return (
    <ErrorLayout code={403} title="Administrators only" documentTitle="Administrators only">
      <p className="-mt-3 text-[0.9375rem] leading-6 text-muted-foreground">
        {me ? (
          <>
            You are logged in as <b className="font-medium text-foreground">{me.user.email}</b> (
            {me.user.role}). Log in as an administrator to open this page.
          </>
        ) : (
          'This page is for administrators. Log in with an administrator account to open it.'
        )}
      </p>
      <div className="flex flex-wrap justify-center gap-2">
        <Link to={`/login?next=${next}`} className={buttonVariants()}>
          <LogIn aria-hidden />
          Log in as an administrator
        </Link>
        <Link to="/packages" className={buttonVariants({ variant: 'outline' })}>
          Packages
        </Link>
      </div>
    </ErrorLayout>
  )
}

/** The error element of the router: a crash while rendering or loading. */
export function RouteErrorPage() {
  const error = useRouteError()
  return (
    <main className="mx-auto grid min-h-screen max-w-[560px] place-content-center justify-items-center gap-5 px-4 py-16 text-center">
      <ErrorCode code={500} />
      <h1 className="text-2xl font-semibold tracking-[-0.015em]">Something went wrong</h1>
      <p className={cn('-mt-3 text-[0.9375rem] leading-6 text-muted-foreground')}>
        {errorMessage(error)} Try again in a moment; if it keeps happening, tell your administrator.
      </p>
      <div className="flex flex-wrap justify-center gap-2">
        <Button onClick={() => window.location.reload()}>
          <RotateCw aria-hidden />
          Reload the page
        </Button>
        <a href={`${basePath}/`} className={buttonVariants({ variant: 'outline' })}>
          Home
        </a>
      </div>
    </main>
  )
}
