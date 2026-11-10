import type { ReactNode } from 'react'
import { CircleAlert, Inbox, RotateCw, SearchX } from 'lucide-react'
import { Link } from 'react-router'
import { ApiError, errorMessage } from '@/api/client'
import { Button } from '@/components/ui/button'
import { Skeleton } from '@/components/ui/skeleton'
import { cn } from '@/lib/utils'

export function EmptyState({
  title,
  children,
  icon: Icon = Inbox,
  className,
}: {
  title: string
  children?: ReactNode
  icon?: typeof Inbox
  className?: string
}) {
  return (
    <div
      className={cn(
        'flex flex-col items-center gap-3 rounded-lg border border-dashed px-6 py-12 text-center',
        className,
      )}
    >
      <Icon aria-hidden className="size-8 text-muted-foreground" />
      <h2 className="text-lg font-semibold">{title}</h2>
      {children && <div className="max-w-prose text-sm text-muted-foreground">{children}</div>}
    </div>
  )
}

export function ErrorState({
  error,
  onRetry,
  title = 'This could not be loaded',
  className,
}: {
  error: unknown
  onRetry?: () => void
  title?: string
  className?: string
}) {
  return (
    <div
      role="alert"
      className={cn(
        'flex flex-col items-center gap-3 rounded-lg border border-destructive/40 px-6 py-10 text-center',
        className,
      )}
    >
      <CircleAlert aria-hidden className="size-8 text-destructive" />
      <h2 className="text-lg font-semibold">{title}</h2>
      <p className="max-w-prose text-sm text-muted-foreground">{errorMessage(error)}</p>
      {onRetry && (
        <Button variant="outline" onClick={onRetry}>
          <RotateCw aria-hidden />
          Try again
        </Button>
      )}
    </div>
  )
}

export function isNotFound(error: unknown) {
  return error instanceof ApiError && error.status === 404
}

export function NotFoundState({ what = 'page' }: { what?: string }) {
  return (
    <EmptyState icon={SearchX} title={`This ${what} does not exist`}>
      <p>
        Check the address, or{' '}
        <Link to="/packages" className="font-medium text-primary underline underline-offset-4">
          search the packages
        </Link>
        .
      </p>
    </EmptyState>
  )
}

/** Rows of skeletons standing in for a list or a table while it loads. */
export function ListSkeleton({ rows = 5, label = 'Loading' }: { rows?: number; label?: string }) {
  return (
    <div aria-busy="true" aria-live="polite" className="grid gap-3">
      <span className="sr-only">{label}…</span>
      {Array.from({ length: rows }, (_, index) => (
        <div key={index} className="grid gap-2 rounded-lg border p-4">
          <Skeleton className="h-5 w-1/3" />
          <Skeleton className="h-4 w-2/3" />
        </div>
      ))}
    </div>
  )
}

export function TableSkeleton({ rows = 8, columns = 4 }: { rows?: number; columns?: number }) {
  return (
    <div aria-busy="true" aria-live="polite" className="grid gap-2 rounded-lg border p-4">
      <span className="sr-only">Loading…</span>
      {Array.from({ length: rows }, (_, row) => (
        <div key={row} className="flex gap-4">
          {Array.from({ length: columns }, (_, column) => (
            <Skeleton key={column} className="h-5 flex-1" />
          ))}
        </div>
      ))}
    </div>
  )
}
