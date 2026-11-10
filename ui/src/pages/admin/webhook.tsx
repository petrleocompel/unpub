import { Fragment, useId, useState, type FormEvent } from 'react'
import { ChevronDown, ChevronRight, KeyRound, Loader2, RotateCw, Send, Trash2 } from 'lucide-react'
import { useNavigate, useParams, useSearchParams } from 'react-router'
import { errorMessage } from '@/api/client'
import {
  useDeleteWebhook,
  useDeliveries,
  useRedeliver,
  useRotateWebhookSecret,
  useUpdateWebhook,
  useWebhook,
} from '@/api/queries'
import type { Delivery, Webhook, WebhookEvent } from '@/api/types'
import { useSession } from '@/auth/session'
import { DeliveryStatusBadge } from '@/components/badges'
import { CodeBlock } from '@/components/copy-button'
import { ConfirmDialog } from '@/components/confirm-dialog'
import { FormError } from '@/components/form'
import { intParam, Pager } from '@/components/pager'
import { SecretBox } from '@/components/secret-box'
import {
  EmptyState,
  ErrorState,
  isNotFound,
  NotFoundState,
  TableSkeleton,
} from '@/components/states'
import { DateTime } from '@/components/time'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Checkbox } from '@/components/ui/checkbox'
import { Label } from '@/components/ui/label'
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table'
import { formatNumber } from '@/lib/format'
import { toast } from '@/lib/toast'
import { useTitle } from '@/lib/use-title'
import { AdminHeading } from './layout'
import { WebhookFields } from './webhooks'

export function WebhookPage() {
  const { id = '' } = useParams()
  const webhook = useWebhook(id)
  useTitle('Webhook')

  if (webhook.isPending) {
    return (
      <>
        <AdminHeading title="Webhook" />
        <TableSkeleton rows={6} />
      </>
    )
  }
  if (webhook.isError) {
    return (
      <>
        <AdminHeading title="Webhook" />
        {isNotFound(webhook.error) ? (
          <NotFoundState what="webhook" />
        ) : (
          <ErrorState error={webhook.error} onRetry={() => void webhook.refetch()} />
        )}
      </>
    )
  }
  return <WebhookDetails webhook={webhook.data.webhook} counts={webhook.data.deliveries} />
}

function WebhookDetails({ webhook, counts }: { webhook: Webhook; counts: Record<string, number> }) {
  const navigate = useNavigate()
  const rotate = useRotateWebhookSecret()
  const remove = useDeleteWebhook()
  const [secret, setSecret] = useState<string | null>(null)
  const [rotating, setRotating] = useState(false)
  const [deleting, setDeleting] = useState(false)

  return (
    <>
      <AdminHeading
        title="Webhook"
        description={<span className="font-mono break-all">{webhook.url}</span>}
        actions={
          <div className="flex gap-2">
            <Button variant="outline" onClick={() => setRotating(true)}>
              <KeyRound aria-hidden />
              Rotate secret…
            </Button>
            <Button variant="destructive" onClick={() => setDeleting(true)}>
              <Trash2 aria-hidden />
              Delete…
            </Button>
          </div>
        }
      />
      <div className="grid gap-6">
        {secret && (
          <SecretBox title="The new signing secret" secret={secret} label="the webhook secret">
            <p className="text-sm">
              Deliveries are signed with it from now on. Update the receiver.
            </p>
            <div>
              <Button variant="outline" size="sm" onClick={() => setSecret(null)}>
                I have copied it
              </Button>
            </div>
          </SecretBox>
        )}
        <dl className="grid grid-cols-3 gap-4 sm:max-w-lg">
          {(['succeeded', 'pending', 'failed'] as const).map((status) => (
            <div key={status} className="rounded-lg border p-3">
              <dt className="text-xs text-muted-foreground">
                {status === 'succeeded' ? 'Delivered' : status === 'pending' ? 'Pending' : 'Failed'}
              </dt>
              <dd className="text-xl font-semibold tabular-nums">
                {formatNumber(counts[status] ?? 0)}
              </dd>
            </div>
          ))}
        </dl>
        <EditWebhook key={webhook.updatedAt} webhook={webhook} />
        <Deliveries webhook={webhook} />
        <PayloadHelp events={webhook.events} />
      </div>
      <ConfirmDialog
        open={rotating}
        onOpenChange={setRotating}
        title="Rotate the signing secret?"
        description="A new secret replaces the current one at once. Receivers verifying signatures fail until they have the new one."
        confirmLabel="Rotate secret"
        destructive
        checkbox="I will update every receiver of this webhook."
        onConfirm={async () => {
          const result = await rotate.mutateAsync(webhook.id)
          setSecret(result.secret)
          toast.success('Secret rotated', 'Copy it now, it is shown once.')
        }}
      />
      <ConfirmDialog
        open={deleting}
        onOpenChange={setDeleting}
        title="Delete this webhook?"
        description="The webhook and its delivery log are deleted. Pending deliveries are not sent."
        confirmLabel="Delete webhook"
        destructive
        onConfirm={async () => {
          await remove.mutateAsync(webhook.id)
          toast.success('Webhook deleted')
          navigate('/admin/webhooks', { replace: true })
        }}
      />
    </>
  )
}

function EditWebhook({ webhook }: { webhook: Webhook }) {
  const id = useId()
  const update = useUpdateWebhook()
  const [url, setUrl] = useState(webhook.url)
  const [events, setEvents] = useState<WebhookEvent[]>(webhook.events)
  const [description, setDescription] = useState(webhook.description)
  const [enabled, setEnabled] = useState(webhook.enabled)

  const submit = (event: FormEvent) => {
    event.preventDefault()
    update.mutate(
      { id: webhook.id, url: url.trim(), events, description, enabled },
      { onSuccess: () => toast.success('Webhook saved') },
    )
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle>
          <h2>Settings</h2>
        </CardTitle>
        <CardDescription>
          Created <DateTime value={webhook.createdAt} />
          {webhook.createdBy && <> by {webhook.createdBy}</>}.
        </CardDescription>
      </CardHeader>
      <CardContent>
        <form onSubmit={submit} className="grid max-w-2xl gap-4">
          <WebhookFields
            idPrefix={id}
            url={url}
            setUrl={setUrl}
            events={events}
            setEvents={setEvents}
            description={description}
            setDescription={setDescription}
          />
          <div className="flex items-center gap-2">
            <Checkbox
              id={`${id}-enabled`}
              checked={enabled}
              onCheckedChange={(value) => setEnabled(value === true)}
            />
            <Label htmlFor={`${id}-enabled`} className="font-normal">
              Enabled: send deliveries for these events
            </Label>
          </div>
          <FormError
            id={`${id}-error`}
            message={update.error ? errorMessage(update.error) : null}
          />
          <div>
            <Button type="submit" disabled={update.isPending || events.length === 0}>
              {update.isPending && <Loader2 aria-hidden className="animate-spin" />}
              Save
            </Button>
          </div>
        </form>
      </CardContent>
    </Card>
  )
}

function Deliveries({ webhook }: { webhook: Webhook }) {
  const [params] = useSearchParams()
  const page = intParam(params, 'page', 1)
  const deliveries = useDeliveries(webhook.id, page)
  const redeliver = useRedeliver()
  const [open, setOpen] = useState<string | null>(null)

  return (
    <Card>
      <CardHeader className="flex flex-row items-start justify-between gap-2">
        <div className="grid gap-1.5">
          <CardTitle>
            <h2>Deliveries</h2>
          </CardTitle>
          <CardDescription>Newest first. Failed attempts are retried with backoff.</CardDescription>
        </div>
        <Button
          variant="ghost"
          size="sm"
          onClick={() => void deliveries.refetch()}
          disabled={deliveries.isFetching}
        >
          <RotateCw aria-hidden className={deliveries.isFetching ? 'animate-spin' : undefined} />
          Refresh
        </Button>
      </CardHeader>
      <CardContent>
        {deliveries.isPending ? (
          <TableSkeleton rows={4} columns={6} />
        ) : deliveries.isError ? (
          <ErrorState error={deliveries.error} onRetry={() => void deliveries.refetch()} />
        ) : deliveries.data.total === 0 ? (
          <EmptyState title="No deliveries yet">
            Deliveries appear when one of its events happens.
          </EmptyState>
        ) : (
          <div className="grid gap-3">
            <Table containerClassName="rounded-lg border" stickyFirstColumn>
              <caption className="sr-only">Deliveries, newest first</caption>
              <TableHeader>
                <TableRow>
                  <TableHead scope="col">
                    <span className="sr-only">Payload</span>
                  </TableHead>
                  <TableHead scope="col">Time</TableHead>
                  <TableHead scope="col">Event</TableHead>
                  <TableHead scope="col">Status</TableHead>
                  <TableHead scope="col" className="text-right">
                    Attempts
                  </TableHead>
                  <TableHead scope="col">Response</TableHead>
                  <TableHead scope="col">Duration</TableHead>
                  <TableHead scope="col">Error</TableHead>
                  <TableHead scope="col">
                    <span className="sr-only">Actions</span>
                  </TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {deliveries.data.items.map((delivery) => (
                  <Fragment key={delivery.id}>
                    <TableRow>
                      <TableCell className="w-10">
                        <Button
                          variant="ghost"
                          size="icon-xs"
                          aria-expanded={open === delivery.id}
                          aria-controls={`payload-${delivery.id}`}
                          aria-label={
                            open === delivery.id ? 'Hide the payload' : 'Show the payload'
                          }
                          onClick={() => setOpen(open === delivery.id ? null : delivery.id)}
                        >
                          {open === delivery.id ? (
                            <ChevronDown aria-hidden />
                          ) : (
                            <ChevronRight aria-hidden />
                          )}
                        </Button>
                      </TableCell>
                      <TableCell>
                        <DateTime value={delivery.createdAt} />
                      </TableCell>
                      <TableCell>
                        <div className="grid">
                          <span className="font-mono text-xs">{delivery.event}</span>
                          {delivery.package && (
                            <span className="text-xs text-muted-foreground">
                              {delivery.package} {delivery.version}
                            </span>
                          )}
                        </div>
                      </TableCell>
                      <TableCell>
                        <DeliveryStatusBadge status={delivery.status} />
                      </TableCell>
                      <TableCell className="text-right tabular-nums">{delivery.attempt}</TableCell>
                      <TableCell className="font-mono text-xs">
                        {delivery.response?.status ?? '–'}
                      </TableCell>
                      <TableCell className="text-xs">{duration(delivery)}</TableCell>
                      <TableCell
                        className="max-w-64 truncate text-xs"
                        title={delivery.error ?? undefined}
                      >
                        {delivery.error ?? '–'}
                      </TableCell>
                      <TableCell className="text-right">
                        <Button
                          variant="ghost"
                          size="sm"
                          disabled={delivery.status === 'pending' || redeliver.isPending}
                          onClick={() =>
                            redeliver.mutate(
                              { id: webhook.id, delivery: delivery.id },
                              {
                                onSuccess: () => {
                                  toast.success('Delivery queued again')
                                  void deliveries.refetch()
                                },
                                onError: (error) =>
                                  toast.error('Redelivery failed', errorMessage(error)),
                              },
                            )
                          }
                        >
                          <Send aria-hidden />
                          Redeliver
                        </Button>
                      </TableCell>
                    </TableRow>
                    {open === delivery.id && (
                      <TableRow id={`payload-${delivery.id}`}>
                        <TableCell colSpan={9} className="bg-muted/40 whitespace-normal">
                          <div className="grid gap-3 py-1">
                            <CodeBlock code={pretty(delivery.payload)} label="the payload" />
                            <p className="text-xs text-muted-foreground">
                              The body as sent and signed is the compact form of this JSON. Delivery
                              id <code className="font-mono">{delivery.id}</code>, event id{' '}
                              <code className="font-mono">{delivery.eventId}</code>
                              {delivery.redeliveryOf && (
                                <>
                                  , a redelivery of{' '}
                                  <code className="font-mono">{delivery.redeliveryOf}</code>
                                </>
                              )}
                              .
                            </p>
                            {delivery.response?.body && (
                              <div className="grid gap-1">
                                <p className="text-xs font-medium">Response body (start)</p>
                                <pre className="max-h-40 overflow-auto rounded-md border bg-background p-2 font-mono text-xs">
                                  {delivery.response.body}
                                </pre>
                              </div>
                            )}
                          </div>
                        </TableCell>
                      </TableRow>
                    )}
                  </Fragment>
                ))}
              </TableBody>
            </Table>
            <Pager
              page={deliveries.data.page}
              size={deliveries.data.size}
              total={deliveries.data.total}
              label="Delivery pages"
            />
          </div>
        )}
      </CardContent>
    </Card>
  )
}

/** How long the last attempt took. */
function duration(delivery: Delivery) {
  const ms = delivery.durationMs
  if (ms === null || ms === undefined) return '–'
  return ms < 1000 ? `${ms} ms` : `${(ms / 1000).toFixed(1)} s`
}

/** The payload, indented when it is JSON. */
function pretty(payload: string) {
  try {
    return JSON.stringify(JSON.parse(payload), null, 2)
  } catch {
    return payload
  }
}

function PayloadHelp({ events }: { events: WebhookEvent[] }) {
  const { config } = useSession()
  const event = events[0] ?? 'package.published'
  const payload = JSON.stringify(
    {
      id: '673071c9a1b2c3d4e5f60718',
      event,
      at: '2026-11-10T09:12:00.000Z',
      package: 'my_company_core',
      ...(event.startsWith('version.') || event === 'package.published'
        ? { version: '1.4.0' }
        : {}),
      actor: 'jane.doe@company.example',
      data:
        event === 'package.published' ? { uploader: 'jane.doe@company.example', sha256: '…' } : {},
    },
    null,
    2,
  )
  return (
    <Card>
      <CardHeader>
        <CardTitle>
          <h2>Payload and signature</h2>
        </CardTitle>
        <CardDescription>Each delivery is a POST of a JSON body like this one.</CardDescription>
      </CardHeader>
      <CardContent className="grid gap-4 text-sm">
        <CodeBlock code={payload} label="the example payload" />
        <dl className="grid gap-2 sm:grid-cols-[14rem_1fr]">
          <dt className="font-mono">X-Unpub-Event</dt>
          <dd>The event, such as {event}.</dd>
          <dt className="font-mono">X-Unpub-Delivery</dt>
          <dd>The id of this delivery, new for every redelivery.</dd>
          <dt className="font-mono">X-Unpub-Signature</dt>
          <dd>
            <code className="font-mono">sha256=&lt;hex&gt;</code>: the HMAC-SHA256 of the exact
            body, keyed with the secret. Compare it in constant time.
          </dd>
          <dt className="font-mono">User-Agent</dt>
          <dd>unpub/{config.version}</dd>
        </dl>
        <p>
          The payload <code className="font-mono">id</code> stays the same when a delivery is sent
          again, so receivers can drop duplicates. To check a signature in a shell, with the body in{' '}
          <code className="font-mono">body.json</code>:
        </p>
        <CodeBlock
          code={`printf 'sha256=%s\\n' "$(openssl dgst -sha256 -hmac "$SECRET" -hex < body.json | sed 's/^.* //')"`}
          label="the verification command"
        />
      </CardContent>
    </Card>
  )
}
