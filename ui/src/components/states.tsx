import type { ReactNode } from 'react'
import { CircleAlert, Inbox, RotateCw, SearchX } from 'lucide-react'
import { Link } from 'react-router'
import { ApiError, errorMessage } from '@/api/client'
import { Button } from '@/components/ui/button'
import { Skeleton } from '@/components/ui/skeleton'
import { cn } from '@/lib/utils'

/** The 48 px icon tile of the empty, error and login states (board 02). */
export function IconTile({ icon: Icon, className }: { icon: typeof Inbox; className?: string }) {
  return (
    <span
      aria-hidden
      className={cn(
        'grid size-12 shrink-0 place-items-center rounded-xl border bg-background text-muted-foreground shadow-xs [&>svg]:size-5',
        className,
      )}
    >
      <Icon />
    </span>
  )
}

export function EmptyState({
  title,
  children,
  icon: Icon = Inbox,
  className,
}: {
  title: ReactNode
  children?: ReactNode
  icon?: typeof Inbox
  className?: string
}) {
  return (
    <div
      className={cn(
        'grid justify-items-center gap-2.5 rounded-lg border border-dashed bg-surface px-6 py-12 text-center',
        className,
      )}
    >
      <IconTile icon={Icon} />
      <h2 className="text-base font-semibold">{title}</h2>
      {children && (
        <div className="grid w-full max-w-[460px] justify-items-center gap-2.5 text-[0.84375rem] text-muted-foreground">
          {children}
        </div>
      )}
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
        'grid justify-items-center gap-2.5 rounded-lg border border-[color-mix(in_oklab,var(--destructive)_35%,var(--border))] bg-background px-6 py-12 text-center',
        className,
      )}
    >
      <IconTile icon={CircleAlert} className="text-destructive" />
      <h2 className="text-base font-semibold">{title}</h2>
      <p className="max-w-[460px] text-[0.84375rem] text-muted-foreground">{errorMessage(error)}</p>
      {onRetry && (
        <Button variant="outline" size="sm" onClick={onRetry}>
          <RotateCw aria-hidden />
          Retry
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
        <Link to="/packages" className="font-medium text-primary underline underline-offset-3">
          search the packages
        </Link>
        .
      </p>
    </EmptyState>
  )
}

/**
 * Rows of skeletons standing in for the package list while it loads, shaped
 * like the real rows so nothing jumps.
 */
export function ListSkeleton({ rows = 5, label = 'Loading' }: { rows?: number; label?: string }) {
  return (
    <div aria-busy="true" aria-live="polite" className="divide-y rounded-lg border bg-card">
      <span className="sr-only">{label}…</span>
      {Array.from({ length: rows }, (_, index) => (
        <div
          key={index}
          className="grid gap-x-6 gap-y-2 px-4 py-3.5 sm:grid-cols-[minmax(0,1fr)_auto] sm:px-5 sm:py-4"
        >
          <div className="grid gap-2">
            <Skeleton className="h-4.5 w-[44%]" />
            <Skeleton className="h-3 w-[92%]" />
            <Skeleton className="h-3 w-[70%]" />
            <Skeleton className="h-5 w-13" />
          </div>
          <div className="hidden justify-items-end gap-2 sm:grid">
            <Skeleton className="h-3 w-14" />
            <Skeleton className="h-3 w-18" />
          </div>
        </div>
      ))}
    </div>
  )
}

export function TableSkeleton({ rows = 8, columns = 4 }: { rows?: number; columns?: number }) {
  return (
    <div aria-busy="true" aria-live="polite" className="overflow-hidden rounded-lg border bg-card">
      <span className="sr-only">Loading…</span>
      <div className="flex h-9 items-center gap-4 border-b bg-surface px-3">
        {Array.from({ length: columns }, (_, column) => (
          <Skeleton key={column} className="h-3 flex-1" />
        ))}
      </div>
      {Array.from({ length: rows }, (_, row) => (
        <div key={row} className="flex h-10 items-center gap-4 border-b px-3 last:border-0">
          {Array.from({ length: columns }, (_, column) => (
            <Skeleton key={column} className="h-3.5 flex-1" />
          ))}
        </div>
      ))}
    </div>
  )
}
