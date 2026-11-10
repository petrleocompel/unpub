import { useState } from 'react'
import { Lock, SearchX, ServerCrash } from 'lucide-react'
import { Link, useLocation, useNavigate, useRouteError } from 'react-router'
import { errorMessage } from '@/api/client'
import { Button, buttonVariants } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Page } from '@/layout/root'
import { basePath } from '@/lib/base'
import { useTitle } from '@/lib/use-title'

function ErrorLayout({
  icon: Icon,
  code,
  title,
  children,
}: {
  icon: typeof Lock
  code: number
  title: string
  children: React.ReactNode
}) {
  useTitle(title)
  return (
    <Page>
      <section className="mx-auto grid max-w-lg justify-items-center gap-4 py-16 text-center">
        <Icon aria-hidden className="size-10 text-muted-foreground" />
        <p className="font-mono text-sm text-muted-foreground">{code}</p>
        <h1 className="text-2xl font-semibold">{title}</h1>
        {children}
      </section>
    </Page>
  )
}

export function NotFoundPage({ what = 'page' }: { what?: string }) {
  const navigate = useNavigate()
  const [query, setQuery] = useState('')
  return (
    <ErrorLayout icon={SearchX} code={404} title={`This ${what} does not exist`}>
      <p className="text-muted-foreground">
        Check the address, or search for what you are looking for.
      </p>
      <form
        role="search"
        className="flex w-full gap-2"
        onSubmit={(event) => {
          event.preventDefault()
          navigate(`/packages${query.trim() ? `?q=${encodeURIComponent(query.trim())}` : ''}`)
        }}
      >
        <label htmlFor="not-found-search" className="sr-only">
          Search packages
        </label>
        <Input
          id="not-found-search"
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          placeholder="Search packages"
        />
        <Button type="submit">Search</Button>
      </form>
    </ErrorLayout>
  )
}

export function ForbiddenPage() {
  const location = useLocation()
  const next = encodeURIComponent(`${location.pathname}${location.search}`)
  return (
    <ErrorLayout icon={Lock} code={403} title="You may not open this page">
      <p className="text-muted-foreground">
        It is for administrators. Log in with an administrator account to continue.
      </p>
      <Link to={`/login?next=${next}`} className={buttonVariants()}>
        Log in as an administrator
      </Link>
    </ErrorLayout>
  )
}

/** The error element of the router: a crash while rendering or loading. */
export function RouteErrorPage() {
  const error = useRouteError()
  return (
    <main className="mx-auto grid max-w-lg justify-items-center gap-4 px-4 py-16 text-center">
      <ServerCrash aria-hidden className="size-10 text-muted-foreground" />
      <p className="font-mono text-sm text-muted-foreground">500</p>
      <h1 className="text-2xl font-semibold">Something went wrong</h1>
      <p className="text-muted-foreground">{errorMessage(error)}</p>
      <div className="flex gap-2">
        <Button onClick={() => window.location.reload()}>Reload the page</Button>
        <a href={`${basePath}/`} className={buttonVariants({ variant: 'outline' })}>
          Home
        </a>
      </div>
    </main>
  )
}
