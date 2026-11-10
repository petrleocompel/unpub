import type { ReactNode } from 'react'
import {
  Boxes,
  ChevronRight,
  CircleAlert,
  Database,
  HardDrive,
  Tag,
  Users,
  Webhook,
  type LucideIcon,
} from 'lucide-react'
import { Link } from 'react-router'
import { useOverview } from '@/api/queries'
import type { Overview } from '@/api/types'
import { useSession } from '@/auth/session'
import { PrereleaseBadge } from '@/components/badges'
import { CompactTable } from '@/components/dashboard/compact-table'
import { Dot, Panel, PanelBody, PanelFooter, PanelHeader } from '@/components/dashboard/panel'
import { ErrorState } from '@/components/states'
import { RelativeTime } from '@/components/time'
import { Badge } from '@/components/ui/badge'
import { Skeleton } from '@/components/ui/skeleton'
import { TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { formatBytes, formatNumber, isPrerelease } from '@/lib/format'
import { cn } from '@/lib/utils'
import { useTitle } from '@/lib/use-title'
import { AdminHeading } from './layout'

const checkNames: Record<string, { label: string; icon: LucideIcon }> = {
  mongo: { label: 'MongoDB', icon: Database },
  storage: { label: 'Storage', icon: HardDrive },
}

/** A readiness check of the server as a badge: ready, or not with its error beside it. */
function ReadinessBadge({
  name,
  check,
}: {
  name: string
  check: { status: string; error?: string }
}) {
  const known = checkNames[name]
  const Icon = known?.icon ?? Database
  const label = known?.label ?? name
  const ok = check.status === 'ok'
  const badge = (
    <Badge variant={ok ? 'success' : 'danger'}>
      {ok ? <Icon aria-hidden /> : <CircleAlert aria-hidden />}
      {ok ? `${label} ready` : `${label} not ready`}
    </Badge>
  )
  if (ok || !check.error) return badge
  return (
    <span className="inline-flex max-w-full items-center gap-1.5">
      {badge}
      <span className="min-w-0 text-xs break-words text-destructive">
        <span className="sr-only">: </span>
        {check.error}
      </span>
    </span>
  )
}

function Tile({
  label,
  icon: Icon,
  value,
  to,
  children,
}: {
  label: string
  icon: LucideIcon
  value: ReactNode
  to?: string
  children?: ReactNode
}) {
  const body = (
    <>
      <p className="flex items-center gap-1.5 text-[0.8125rem] text-muted-foreground">
        <Icon aria-hidden className="size-3.5" />
        {label}
      </p>
      <p className="text-[1.625rem] leading-8 font-semibold tracking-[-0.02em] tabular-nums">
        {value}
      </p>
      {children && <div className="text-xs text-muted-foreground">{children}</div>}
    </>
  )
  const className = 'grid content-start rounded-lg border bg-card px-4.5 py-4 text-card-foreground'
  return to ? (
    <Link
      to={to}
      className={cn(
        className,
        'outline-none hover:border-ring/60 focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 focus-visible:ring-offset-background',
      )}
    >
      {body}
    </Link>
  ) : (
    <div className={className}>{body}</div>
  )
}

export function OverviewPage() {
  useTitle('Admin')
  const overview = useOverview()
  const { config } = useSession()
  const host = (() => {
    const base = config.publicUrl ?? window.location.origin
    try {
      return new URL(base).host
    } catch {
      return base
    }
  })()
  const description = (
    <>
      <span className="font-mono">{host}</span> · unpub {config.version}
    </>
  )

  if (overview.isPending) {
    return (
      <div aria-busy="true" aria-live="polite">
        <AdminHeading title="Overview" description={description} />
        <span className="sr-only">Loading the overview…</span>
        <div className="grid gap-6">
          <div className="grid grid-cols-2 gap-4 lg:grid-cols-5">
            {Array.from({ length: 5 }, (_, index) => (
              <Skeleton key={index} className="h-26" />
            ))}
          </div>
          <Skeleton className="h-64" />
        </div>
      </div>
    )
  }
  if (overview.isError) {
    return (
      <>
        <AdminHeading title="Overview" description={description} />
        <ErrorState error={overview.error} onRetry={() => void overview.refetch()} />
      </>
    )
  }
  const data = overview.data
  const webhooks = config.features.webhooks

  return (
    <>
      <AdminHeading
        title="Overview"
        description={description}
        actions={Object.entries(data.readiness.checks).map(([name, check]) => (
          <ReadinessBadge key={name} name={name} check={check} />
        ))}
      />
      <div className="grid gap-6">
        <div className="grid grid-cols-2 gap-4 lg:grid-cols-5">
          <Tile
            label="Packages"
            icon={Boxes}
            value={formatNumber(data.packages)}
            to="/admin/packages"
          />
          <Tile label="Versions" icon={Tag} value={formatNumber(data.versions)}>
            {formatNumber(data.publishesLast24h)} published in 24 h
          </Tile>
          <Tile label="Users" icon={Users} value={formatNumber(data.users)} to="/admin/users" />
          <Tile
            label="Webhooks"
            icon={Webhook}
            value={formatNumber(data.webhooks)}
            to={webhooks ? '/admin/webhooks' : undefined}
          >
            {data.failedDeliveriesLast24h > 0 && (
              <p className="flex items-center gap-1 text-destructive">
                <CircleAlert aria-hidden className="size-3" />
                {formatNumber(data.failedDeliveriesLast24h)} failed in 24 h
              </p>
            )}
          </Tile>
          <Tile label="Storage" icon={HardDrive} value={formatBytes(data.storageBytes)}>
            {data.storageMeasuredAt && (
              <>
                measured <RelativeTime value={data.storageMeasuredAt} />
              </>
            )}
          </Tile>
        </div>

        <div
          className={cn(
            'grid items-start gap-6',
            webhooks && 'lg:grid-cols-[minmax(0,1.5fr)_minmax(0,1fr)]',
          )}
        >
          <RecentPublishes events={data.recentPublishes} />
          {webhooks && <FailedDeliveries count={data.failedDeliveriesLast24h} />}
        </div>
      </div>
    </>
  )
}

function RecentPublishes({ events }: { events: Overview['recentPublishes'] }) {
  return (
    <Panel aria-labelledby="recent-publishes">
      <PanelHeader title="Recent publishes" titleId="recent-publishes">
        <Link
          to="/admin/audit?action=package.published"
          className="inline-flex items-center gap-0.5 text-[0.8125rem] font-medium text-primary hover:underline"
        >
          Audit log
          <ChevronRight aria-hidden className="size-3.5" />
        </Link>
      </PanelHeader>
      {events.length === 0 ? (
        <PanelBody>
          <p className="text-sm text-muted-foreground">Nothing has been published yet.</p>
        </PanelBody>
      ) : (
        <CompactTable boxed={false} containerClassName="rounded-b-lg">
          <caption className="sr-only">The last publishes, newest first</caption>
          <TableHeader>
            <TableRow>
              <TableHead scope="col">Package</TableHead>
              <TableHead scope="col">Version</TableHead>
              <TableHead scope="col">By</TableHead>
              <TableHead scope="col">When</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {events.map((event, index) => (
              <TableRow key={`${event.at}-${index}`}>
                <TableCell>
                  {event.package ? (
                    <Link
                      to={`/admin/packages/${encodeURIComponent(event.package)}`}
                      className="font-medium text-primary hover:underline"
                    >
                      {event.package}
                    </Link>
                  ) : (
                    '–'
                  )}
                </TableCell>
                <TableCell>
                  <div className="flex items-center gap-2">
                    <span className="font-mono">{event.version ?? '–'}</span>
                    {event.version && isPrerelease(event.version) && <PrereleaseBadge />}
                  </div>
                </TableCell>
                <TableCell className="text-muted-foreground">
                  {event.actor ?? '–'}
                  {event.actorKind === 'token' && ' · token'}
                </TableCell>
                <TableCell>
                  <RelativeTime value={event.at} />
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </CompactTable>
      )}
    </Panel>
  )
}

/**
 * The failed deliveries of the last day. The overview has their count only,
 * so the list of attempts is on each webhook's page.
 */
function FailedDeliveries({ count }: { count: number }) {
  return (
    <Panel aria-labelledby="failed-deliveries">
      <PanelHeader title="Failed deliveries · 24 h" titleId="failed-deliveries">
        {count > 0 ? (
          <Badge variant="danger">
            <Dot tone="danger" />
            {formatNumber(count)} failed
          </Badge>
        ) : (
          <Badge variant="success">
            <Dot tone="success" />
            None failed
          </Badge>
        )}
      </PanelHeader>
      <PanelBody className="text-[0.8125rem] text-muted-foreground">
        {count > 0
          ? `${formatNumber(count)} ${count === 1 ? 'delivery' : 'deliveries'} failed in the last 24 hours. Each webhook lists its attempts, with the response, and can send one again.`
          : 'Every delivery of the last 24 hours went through, or is still being retried.'}
      </PanelBody>
      <PanelFooter className="justify-start">
        <Link
          to="/admin/webhooks"
          className="inline-flex items-center gap-0.5 text-[0.8125rem] font-medium text-primary hover:underline"
        >
          All webhooks
          <ChevronRight aria-hidden className="size-3.5" />
        </Link>
      </PanelFooter>
    </Panel>
  )
}
