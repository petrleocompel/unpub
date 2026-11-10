import { CircleCheck, CircleX } from 'lucide-react'
import { Link } from 'react-router'
import { useOverview } from '@/api/queries'
import { useSession } from '@/auth/session'
import { ErrorState } from '@/components/states'
import { RelativeTime } from '@/components/time'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Skeleton } from '@/components/ui/skeleton'
import { formatBytes, formatNumber } from '@/lib/format'
import { cn } from '@/lib/utils'
import { useTitle } from '@/lib/use-title'
import { packagePath } from '@/pages/package'
import { AdminHeading } from './layout'

export function OverviewPage() {
  useTitle('Admin')
  const overview = useOverview()
  const { config } = useSession()

  if (overview.isPending) {
    return (
      <div aria-busy="true" aria-live="polite" className="grid gap-4">
        <AdminHeading title="Overview" />
        <span className="sr-only">Loading the overview…</span>
        <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
          {Array.from({ length: 4 }, (_, index) => (
            <Skeleton key={index} className="h-24" />
          ))}
        </div>
        <Skeleton className="h-48" />
      </div>
    )
  }
  if (overview.isError) {
    return (
      <>
        <AdminHeading title="Overview" />
        <ErrorState error={overview.error} onRetry={() => void overview.refetch()} />
      </>
    )
  }
  const data = overview.data
  const counts = [
    { label: 'Packages', value: data.packages, to: '/admin/packages' },
    { label: 'Versions', value: data.versions },
    { label: 'Users', value: data.users, to: '/admin/users' },
    {
      label: 'Webhooks',
      value: data.webhooks,
      to: config.features.webhooks ? '/admin/webhooks' : undefined,
    },
  ]
  const checks = Object.entries(data.readiness.checks)

  return (
    <>
      <AdminHeading
        title="Overview"
        description={
          config.features.metrics ? (
            <>
              Prometheus metrics are at{' '}
              <a className="text-primary underline underline-offset-4" href="/metrics">
                /metrics
              </a>
              .
            </>
          ) : undefined
        }
      />
      <div className="grid gap-6">
        <dl className="grid grid-cols-2 gap-4 lg:grid-cols-4">
          {counts.map((count) => (
            <div key={count.label} className="rounded-lg border p-4">
              <dt className="text-sm text-muted-foreground">
                {count.to ? (
                  <Link to={count.to} className="hover:underline">
                    {count.label}
                  </Link>
                ) : (
                  count.label
                )}
              </dt>
              <dd className="text-2xl font-semibold tabular-nums">{formatNumber(count.value)}</dd>
            </div>
          ))}
          <div className="rounded-lg border p-4">
            <dt className="text-sm text-muted-foreground">Storage</dt>
            <dd className="text-2xl font-semibold tabular-nums">
              {formatBytes(data.storageBytes)}
            </dd>
            {data.storageMeasuredAt && (
              <dd className="text-xs text-muted-foreground">
                measured <RelativeTime value={data.storageMeasuredAt} />
              </dd>
            )}
          </div>
          <div className="rounded-lg border p-4">
            <dt className="text-sm text-muted-foreground">Publishes, last 24 h</dt>
            <dd className="text-2xl font-semibold tabular-nums">
              {formatNumber(data.publishesLast24h)}
            </dd>
          </div>
          <div
            className={cn(
              'rounded-lg border p-4',
              data.failedDeliveriesLast24h > 0 && 'border-destructive/50',
            )}
          >
            <dt className="text-sm text-muted-foreground">Failed deliveries, last 24 h</dt>
            <dd className="text-2xl font-semibold tabular-nums">
              {formatNumber(data.failedDeliveriesLast24h)}
            </dd>
          </div>
        </dl>

        <div className="grid gap-6 lg:grid-cols-[minmax(0,2fr)_minmax(0,1fr)]">
          <Card>
            <CardHeader>
              <CardTitle>
                <h2>Last publishes</h2>
              </CardTitle>
            </CardHeader>
            <CardContent>
              {data.recentPublishes.length === 0 ? (
                <p className="text-sm text-muted-foreground">Nothing has been published yet.</p>
              ) : (
                <ul className="divide-y">
                  {data.recentPublishes.map((event, index) => (
                    <li
                      key={`${event.at}-${index}`}
                      className="flex flex-wrap items-baseline justify-between gap-2 py-2 text-sm"
                    >
                      <span>
                        {event.package ? (
                          <Link
                            to={packagePath(event.package, event.version ?? undefined)}
                            className="font-medium text-primary hover:underline"
                          >
                            {event.package} <span className="font-mono">{event.version}</span>
                          </Link>
                        ) : (
                          '–'
                        )}
                        {event.actor && (
                          <span className="text-muted-foreground"> by {event.actor}</span>
                        )}
                      </span>
                      <span className="text-muted-foreground">
                        <RelativeTime value={event.at} />
                      </span>
                    </li>
                  ))}
                </ul>
              )}
            </CardContent>
          </Card>
          <Card>
            <CardHeader>
              <CardTitle>
                <h2>Health</h2>
              </CardTitle>
            </CardHeader>
            <CardContent>
              <p className="mb-3 flex items-center gap-2 text-sm font-medium">
                {data.readiness.status === 'ok' ? (
                  <CircleCheck aria-hidden className="size-4 text-success" />
                ) : (
                  <CircleX aria-hidden className="size-4 text-destructive" />
                )}
                {data.readiness.status === 'ok' ? 'Ready' : 'Not ready'}
              </p>
              <ul className="grid gap-2 text-sm">
                {checks.map(([name, check]) => (
                  <li key={name} className="grid gap-0.5">
                    <span className="flex items-center gap-2">
                      {check.status === 'ok' ? (
                        <CircleCheck aria-hidden className="size-4 text-success" />
                      ) : (
                        <CircleX aria-hidden className="size-4 text-destructive" />
                      )}
                      <span className="capitalize">{name}</span>
                      <span className="text-muted-foreground">
                        {check.status === 'ok' ? 'OK' : 'Error'}
                      </span>
                    </span>
                    {check.error && (
                      <span className="pl-6 text-xs text-destructive">{check.error}</span>
                    )}
                  </li>
                ))}
              </ul>
            </CardContent>
          </Card>
        </div>
      </div>
    </>
  )
}
