import { Fragment, useId, useState, type FormEvent } from 'react'
import { ChevronDown, ChevronRight, Filter, RotateCcw } from 'lucide-react'
import { Link, useSearchParams } from 'react-router'
import { useAudit, useSettings, type AuditFilters } from '@/api/queries'
import type { AuditEvent } from '@/api/types'
import { Field } from '@/components/form'
import { NativeSelect } from '@/components/native-select'
import { intParam, Pager } from '@/components/pager'
import { EmptyState, ErrorState, TableSkeleton } from '@/components/states'
import { DateTime } from '@/components/time'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table'
import { useTitle } from '@/lib/use-title'
import { packagePath } from '@/pages/package'
import { AdminHeading } from './layout'

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
  const retention = settings.data?.sections
    .flatMap((section) => section.settings)
    .find((setting) => setting.key === 'audit.retentionDays')?.value
  const active = filterNames.some((name) => filters[name])

  return (
    <>
      <AdminHeading
        title="Audit log"
        description={
          retention === undefined
            ? 'Who changed what, newest first.'
            : retention === '0'
              ? 'Who changed what, newest first. Every event is kept.'
              : `Who changed what, newest first. Events are kept for ${retention} days (audit.retentionDays).`
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
      className="grid gap-3 rounded-lg border p-4 sm:grid-cols-2 lg:grid-cols-[repeat(5,minmax(0,1fr))_auto] lg:items-end"
    >
      <Field id={`${id}-action`} label="Action">
        <NativeSelect
          id={`${id}-action`}
          value={values.action}
          onChange={(event) => set('action')(event.target.value)}
          className="w-full"
        >
          <option value="">Any action</option>
          {auditActions.map((action) => (
            <option key={action} value={action}>
              {action}
            </option>
          ))}
        </NativeSelect>
      </Field>
      <Field id={`${id}-actor`} label="Actor">
        <Input
          id={`${id}-actor`}
          value={values.actor}
          placeholder="email or token:prefix"
          onChange={(event) => set('actor')(event.target.value)}
        />
      </Field>
      <Field id={`${id}-package`} label="Package">
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
      <Field id={`${id}-to`} label="To (inclusive)">
        <Input
          id={`${id}-to`}
          type="date"
          value={values.to}
          onChange={(event) => set('to')(event.target.value)}
        />
      </Field>
      <div className="flex gap-2">
        <Button type="submit">
          <Filter aria-hidden />
          Filter
        </Button>
        {onReset && (
          <Button type="button" variant="ghost" onClick={onReset}>
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
        className="text-primary hover:underline"
      >
        {event.package}
        {event.version && (
          <>
            {' '}
            <span className="font-mono">{event.version}</span>
          </>
        )}
      </Link>
    )
  }
  if (!event.target) return <span className="text-muted-foreground">–</span>
  if (event.action.startsWith('user.')) {
    return (
      <Link
        to={`/admin/users?q=${encodeURIComponent(event.target)}`}
        className="text-primary hover:underline"
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
    <Table containerClassName="rounded-lg border" stickyFirstColumn>
      <caption className="sr-only">Audit events, newest first</caption>
      <TableHeader>
        <TableRow>
          <TableHead scope="col">
            <span className="sr-only">Details</span>
          </TableHead>
          <TableHead scope="col">Time</TableHead>
          <TableHead scope="col">Action</TableHead>
          <TableHead scope="col">Actor</TableHead>
          <TableHead scope="col">Target</TableHead>
          <TableHead scope="col">IP</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {events.map((event, index) => {
          const expanded = open.has(index)
          const hasDetails = Object.keys(event.details).length > 0
          const detailsId = `audit-details-${index}`
          return (
            <Fragment key={`${event.at}-${index}`}>
              <TableRow>
                <TableCell className="w-10">
                  {hasDetails && (
                    <Button
                      variant="ghost"
                      size="icon-xs"
                      aria-expanded={expanded}
                      aria-controls={detailsId}
                      aria-label={expanded ? 'Hide details' : 'Show details'}
                      onClick={() => toggle(index)}
                    >
                      {expanded ? <ChevronDown aria-hidden /> : <ChevronRight aria-hidden />}
                    </Button>
                  )}
                </TableCell>
                <TableCell>
                  <DateTime value={event.at} />
                </TableCell>
                <TableCell>
                  <Badge variant="outline" className="font-mono font-normal">
                    {event.action}
                  </Badge>
                </TableCell>
                <TableCell>
                  <div className="grid">
                    <span>{event.actor ?? '–'}</span>
                    {(event.actorKind || event.token) && (
                      <span className="text-xs text-muted-foreground">
                        {event.actorKind}
                        {event.token && <span className="font-mono"> {event.token}…</span>}
                      </span>
                    )}
                  </div>
                </TableCell>
                <TableCell>
                  <Target event={event} />
                </TableCell>
                <TableCell className="font-mono text-xs">{event.ip ?? '–'}</TableCell>
              </TableRow>
              {expanded && (
                <TableRow id={detailsId}>
                  <TableCell colSpan={6} className="bg-muted/40">
                    <pre className="overflow-x-auto font-mono text-xs leading-5">
                      {JSON.stringify(event.details, null, 2)}
                    </pre>
                  </TableCell>
                </TableRow>
              )}
            </Fragment>
          )
        })}
      </TableBody>
    </Table>
  )
}
