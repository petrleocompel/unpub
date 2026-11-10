import { Fragment, useId, useState, type FormEvent } from 'react'
import { ChevronDown, Clock, Filter, RotateCcw } from 'lucide-react'
import { Link, useSearchParams } from 'react-router'
import { useAudit, useSettings, type AuditFilters } from '@/api/queries'
import type { AuditEvent } from '@/api/types'
import { CodeBlock } from '@/components/copy-button'
import { CompactTable } from '@/components/dashboard/compact-table'
import { Chip } from '@/components/dashboard/panel'
import { Field } from '@/components/form'
import { NativeSelect } from '@/components/native-select'
import { intParam, Pager } from '@/components/pager'
import { EmptyState, ErrorState, TableSkeleton } from '@/components/states'
import { DateTime } from '@/components/time'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { formatRelative } from '@/lib/format'
import { cn } from '@/lib/utils'
import { useTitle } from '@/lib/use-title'
import { packagePath } from '@/pages/package'
import { AdminHeading } from './layout'
import { settingDays } from './settings'

/** The actions the server records, see README "Audit log". */
export const auditActions = [
  'user.login',
  'user.login_failed',
  'user.created',
  'user.updated',
  'user.role_changed',
  'user.disabled',
  'user.enabled',
  'user.password_set',
  'token.created',
  'token.revoked',
  'package.published',
  'package.discontinued',
  'package.continued',
  'package.deleted',
  'version.retracted',
  'version.unretracted',
  'version.deleted',
  'uploader.added',
  'uploader.removed',
  'uploader.transferred',
  'webhook.created',
  'webhook.updated',
  'webhook.deleted',
  'webhook.secret_rotated',
  'webhook.redelivered',
]

const filterNames = ['action', 'actor', 'package', 'from', 'to'] as const

function filtersFrom(params: URLSearchParams): AuditFilters {
  const filters: AuditFilters = { page: intParam(params, 'page', 1), size: 50 }
  for (const name of filterNames) {
    const value = params.get(name)?.trim()
    if (value) filters[name] = value
  }
  return filters
}

export function AuditPage() {
  useTitle('Audit log')
  const [params, setParams] = useSearchParams()
  const filters = filtersFrom(params)
  const audit = useAudit(filters)
  const settings = useSettings()
  const retention = settingDays(settings.data, 'audit.retentionDays')
  const active = filterNames.some((name) => filters[name])

  return (
    <>
      <AdminHeading
        title="Audit log"
        description={
          retention === null ? (
            'Who changed what, newest first.'
          ) : (
            <span className="flex items-center gap-1">
              <Clock aria-hidden className="size-3 shrink-0" />
              {retention === 0 ? (
                <span>
                  Every entry is kept (<span className="font-mono">audit.retentionDays</span> is 0).
                </span>
              ) : (
                <span>
                  Entries are kept for {retention} days (
                  <span className="font-mono">audit.retentionDays</span>).
                </span>
              )}
            </span>
          )
        }
      />
      <div className="grid gap-4">
        <AuditFilterForm
          key={params.toString()}
          initial={filters}
          onApply={(next) => {
            const updated = new URLSearchParams()
            for (const name of filterNames) {
              if (next[name]) updated.set(name, next[name])
            }
            setParams(updated)
          }}
          onReset={active ? () => setParams(new URLSearchParams()) : undefined}
        />
        {audit.isPending ? (
          <TableSkeleton columns={5} />
        ) : audit.isError ? (
          <ErrorState error={audit.error} onRetry={() => void audit.refetch()} />
        ) : audit.data.total === 0 ? (
          <EmptyState title={active ? 'No events match' : 'No events yet'}>
            {active
              ? 'Change or reset the filters.'
              : 'Logins, publishes and changes show up here.'}
          </EmptyState>
        ) : (
          <>
            <AuditTable events={audit.data.items} />
            <Pager
              page={audit.data.page}
              size={audit.data.size}
              total={audit.data.total}
              label="Audit pages"
            />
          </>
        )}
      </div>
    </>
  )
}

function AuditFilterForm({
  initial,
  onApply,
  onReset,
}: {
  initial: AuditFilters
  onApply: (filters: Record<(typeof filterNames)[number], string>) => void
  onReset?: () => void
}) {
  const id = useId()
  const [values, setValues] = useState(
    () =>
      Object.fromEntries(filterNames.map((name) => [name, initial[name] ?? ''])) as Record<
        (typeof filterNames)[number],
        string
      >,
  )
  const set = (name: (typeof filterNames)[number]) => (value: string) =>
    setValues((current) => ({ ...current, [name]: value }))

  const submit = (event: FormEvent) => {
    event.preventDefault()
    onApply(values)
  }

  return (
    <form
      onSubmit={submit}
      aria-label="Filter the audit log"
      className="grid grid-cols-2 items-end gap-3 rounded-lg border bg-card p-3.5 lg:grid-cols-[minmax(0,1.2fr)_minmax(0,1.2fr)_minmax(0,1fr)_minmax(0,0.8fr)_minmax(0,0.8fr)_auto] [&_input]:h-8 [&_input]:text-[0.8125rem] [&_label]:text-xs [&_select]:text-[0.8125rem] [&>div:has(select)>span]:h-8"
    >
      <Field id={`${id}-action`} label="Action" className="col-span-2 sm:col-span-1">
        <NativeSelect
          id={`${id}-action`}
          value={values.action}
          onChange={(event) => set('action')(event.target.value)}
          className="w-full"
        >
          <option value="">All actions</option>
          {auditActions.map((action) => (
            <option key={action} value={action}>
              {action}
            </option>
          ))}
        </NativeSelect>
      </Field>
      <Field id={`${id}-actor`} label="Actor" className="col-span-2 sm:col-span-1">
        <Input
          id={`${id}-actor`}
          value={values.actor}
          placeholder="email"
          onChange={(event) => set('actor')(event.target.value)}
        />
      </Field>
      <Field id={`${id}-package`} label="Package" className="col-span-2 sm:col-span-1">
        <Input
          id={`${id}-package`}
          value={values.package}
          onChange={(event) => set('package')(event.target.value)}
          className="font-mono"
        />
      </Field>
      <Field id={`${id}-from`} label="From">
        <Input
          id={`${id}-from`}
          type="date"
          value={values.from}
          onChange={(event) => set('from')(event.target.value)}
        />
      </Field>
      <Field id={`${id}-to`} label="To">
        <Input
          id={`${id}-to`}
          type="date"
          value={values.to}
          onChange={(event) => set('to')(event.target.value)}
        />
      </Field>
      <div className="col-span-2 flex gap-2 lg:col-span-1">
        <Button type="submit" size="sm">
          <Filter aria-hidden />
          Filter
        </Button>
        {onReset && (
          <Button type="button" variant="ghost" size="sm" onClick={onReset}>
            <RotateCcw aria-hidden />
            Reset
          </Button>
        )}
      </div>
    </form>
  )
}

function Target({ event }: { event: AuditEvent }) {
  if (event.package) {
    return (
      <Link
        to={packagePath(event.package, event.version ?? undefined)}
        className="font-mono font-medium text-primary hover:underline"
      >
        {event.package}
        {event.version && ` ${event.version}`}
      </Link>
    )
  }
  if (!event.target) return <span className="text-muted-foreground">–</span>
  if (event.action.startsWith('user.')) {
    return (
      <Link
        to={`/admin/users?q=${encodeURIComponent(event.target)}`}
        className="font-medium text-primary hover:underline"
      >
        {event.target}
      </Link>
    )
  }
  if (event.action.startsWith('webhook.')) {
    return (
      <Link
        to={`/admin/webhooks/${encodeURIComponent(event.target)}`}
        className="font-mono text-primary hover:underline"
      >
        {event.target}
      </Link>
    )
  }
  return <span className="font-mono">{event.target}</span>
}

function AuditTable({ events }: { events: AuditEvent[] }) {
  const [open, setOpen] = useState<Set<number>>(new Set())
  const toggle = (index: number) =>
    setOpen((current) => {
      const next = new Set(current)
      if (next.has(index)) next.delete(index)
      else next.add(index)
      return next
    })

  return (
    <CompactTable>
      <caption className="sr-only">Audit events, newest first</caption>
      <TableHeader>
        <TableRow>
          <TableHead scope="col">Time</TableHead>
          <TableHead scope="col">Action</TableHead>
          <TableHead scope="col">Actor</TableHead>
          <TableHead scope="col">Target</TableHead>
          <TableHead scope="col">IP</TableHead>
          <TableHead scope="col">
            <span className="sr-only">Details</span>
          </TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {events.map((event, index) => {
          const expanded = open.has(index)
          const hasDetails = Object.keys(event.details).length > 0
          const detailsId = `audit-details-${index}`
          return (
            <Fragment key={`${event.at}-${index}`}>
              <TableRow data-expanded={expanded || undefined}>
                <TableCell>
                  <div className="grid">
                    <DateTime value={event.at} />
                    <span className="text-xs text-muted-foreground">
                      {formatRelative(event.at)}
                    </span>
                  </div>
                </TableCell>
                <TableCell>
                  <Chip>{event.action}</Chip>
                </TableCell>
                <TableCell>
                  <div className="flex items-center gap-2">
                    <span>{event.actor ?? '–'}</span>
                    {event.actorKind && (
                      <Badge
                        variant="outline"
                        className="rounded-[5px] font-mono font-normal"
                        title={event.token ? `Token ${event.token}…` : undefined}
                      >
                        {event.actorKind}
                      </Badge>
                    )}
                  </div>
                </TableCell>
                <TableCell>
                  <Target event={event} />
                </TableCell>
                <TableCell className="font-mono text-xs text-muted-foreground">
                  {event.ip ?? '–'}
                </TableCell>
                <TableCell className="w-10 text-right">
                  {hasDetails && (
                    <Button
                      variant="ghost"
                      size="icon-xs"
                      aria-expanded={expanded}
                      aria-controls={detailsId}
                      aria-label={expanded ? 'Hide details' : 'Show details'}
                      onClick={() => toggle(index)}
                    >
                      <ChevronDown
                        aria-hidden
                        className={cn(
                          'transition-transform motion-reduce:transition-none',
                          expanded && 'rotate-180',
                        )}
                      />
                    </Button>
                  )}
                </TableCell>
              </TableRow>
              {expanded && (
                <TableRow id={detailsId} data-expanded>
                  <TableCell colSpan={6} className="h-auto px-3 pt-0 pb-3 whitespace-normal">
                    <CodeBlock
                      code={JSON.stringify(event.details, null, 2)}
                      title="Details"
                      label="the details as JSON"
                    />
                  </TableCell>
                </TableRow>
              )}
            </Fragment>
          )
        })}
      </TableBody>
    </CompactTable>
  )
}
