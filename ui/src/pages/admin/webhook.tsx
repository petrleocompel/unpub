import { useId, useState, type FormEvent } from 'react'
import { ChevronRight, Loader2, RefreshCw, RotateCw, Send, Trash2 } from 'lucide-react'
import { Link, useNavigate, useParams, useSearchParams } from 'react-router'
import { errorMessage } from '@/api/client'
import {
  useDeleteWebhook,
  useDeliveries,
  useRedeliver,
  useRotateWebhookSecret,
  useSettings,
  useUpdateWebhook,
  useWebhook,
} from '@/api/queries'
import type { Delivery, Webhook, WebhookEvent } from '@/api/types'
import { useSession } from '@/auth/session'
import { DeliveryStatusBadge } from '@/components/badges'
import { CodeBlock } from '@/components/copy-button'
import { ConfirmDialog } from '@/components/confirm-dialog'
import { CompactTable } from '@/components/dashboard/compact-table'
import { Chip, Dot, Panel, PanelBody, PanelHeader } from '@/components/dashboard/panel'
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
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Label } from '@/components/ui/label'
import { Switch } from '@/components/ui/switch'
import { TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { formatDate, formatDateTime, formatRelative } from '@/lib/format'
import { toast } from '@/lib/toast'
import { useTitle } from '@/lib/use-title'
import { AdminHeading } from './layout'
import { settingDays } from './settings'
import { DeliveryCounts, WebhookFields } from './webhooks'

function Breadcrumb({ label }: { label: string }) {
  return (
    <nav aria-label="Breadcrumb">
      <ol className="flex flex-wrap items-center gap-1.5 text-[0.8125rem] text-muted-foreground">
        <li>
          <Link to="/admin/webhooks" className="hover:text-foreground hover:underline">
            Webhooks
          </Link>
        </li>
        <li aria-hidden>
          <ChevronRight className="size-3" />
        </li>
        <li aria-current="page" className="min-w-0 truncate text-foreground">
          {label}
        </li>
      </ol>
    </nav>
  )
}

/** The URL without its scheme, as the title of its page. */
function shortUrl(url: string) {
  return url.replace(/^https?:\/\//, '')
}

export function WebhookPage() {
  const { id = '' } = useParams()
  const webhook = useWebhook(id)
  useTitle('Webhook')

  if (webhook.isPending) {
    return (
      <>
        <AdminHeading title="Webhook" above={<Breadcrumb label="Webhook" />} />
        <TableSkeleton rows={6} />
      </>
    )
  }
  if (webhook.isError) {
    return (
      <>
        <AdminHeading title="Webhook" above={<Breadcrumb label="Webhook" />} />
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
        above={<Breadcrumb label={webhook.description || shortUrl(webhook.url)} />}
        title={webhook.url}
        titleClassName="truncate font-mono text-lg leading-7 md:text-lg md:leading-7"
        description={
          <span className="flex flex-wrap items-center gap-2">
            {webhook.enabled ? (
              <Badge variant="success">
                <Dot tone="success" />
                Enabled
              </Badge>
            ) : (
              <Badge variant="outline">Paused</Badge>
            )}
            <span>
              {webhook.description && `${webhook.description} · `}created{' '}
              {formatDate(webhook.createdAt)}
              {webhook.createdBy && ` by ${webhook.createdBy}`}
            </span>
          </span>
        }
        actions={
          <Button variant="destructive-outline" size="sm" onClick={() => setDeleting(true)}>
            <Trash2 aria-hidden />
            Delete…
          </Button>
        }
      />
      <div className="grid gap-6">
        <div className="grid items-start gap-6 lg:grid-cols-2">
          <EditWebhook key={webhook.updatedAt} webhook={webhook} />
          <SigningSecret
            secret={secret}
            onRotate={() => setRotating(true)}
            onDismiss={() => setSecret(null)}
          />
        </div>
        <Deliveries webhook={webhook} counts={counts} />
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
    <Panel aria-labelledby={`${id}-title`}>
      <PanelHeader title="Settings" titleId={`${id}-title`} />
      <PanelBody>
        <form onSubmit={submit} className="grid gap-4">
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
            <Switch id={`${id}-enabled`} checked={enabled} onCheckedChange={setEnabled} />
            <Label htmlFor={`${id}-enabled`} className="font-normal">
              Enabled: send deliveries for these events
            </Label>
          </div>
          <FormError
            id={`${id}-error`}
            message={update.error ? errorMessage(update.error) : null}
          />
          <div className="flex justify-end">
            <Button type="submit" size="sm" disabled={update.isPending || events.length === 0}>
              {update.isPending && <Loader2 aria-hidden className="animate-spin" />}
              Save changes
            </Button>
          </div>
        </form>
      </PanelBody>
    </Panel>
  )
}

/**
 * The signing secret: rotating it, the new one shown once, and how a
 * receiver verifies a delivery, explained where the secret is.
 */
function SigningSecret({
  secret,
  onRotate,
  onDismiss,
}: {
  secret: string | null
  onRotate: () => void
  onDismiss: () => void
}) {
  const id = useId()
  return (
    <Panel aria-labelledby={`${id}-title`}>
      <PanelHeader title="Signing secret" titleId={`${id}-title`}>
        <Button variant="outline" size="sm" aria-label="Rotate secret…" onClick={onRotate}>
          <RefreshCw aria-hidden />
          Rotate…
        </Button>
      </PanelHeader>
      <PanelBody className="grid gap-4">
        {secret ? (
          <SecretBox title="The new signing secret" secret={secret} label="the webhook secret">
            <p className="text-[0.8125rem] text-muted-foreground">
              The old secret stopped working. Update every receiver.
            </p>
            <div>
              <Button variant="outline" size="sm" onClick={onDismiss}>
                I have copied it
              </Button>
            </div>
          </SecretBox>
        ) : (
          <p className="text-[0.8125rem] text-muted-foreground">
            Only a hash of the secret is stored, so it cannot be shown again. Rotate it to get a new
            one; the current one stops working at once.
          </p>
        )}
        <div className="grid gap-2">
          <h3 className="text-[0.8125rem] font-semibold">Verifying a delivery</h3>
          <p className="text-[0.8125rem] text-muted-foreground">
            Each POST carries{' '}
            <code className="rounded-sm border bg-muted px-1 font-mono text-xs text-foreground">
              X-Unpub-Signature: sha256=&lt;hex&gt;
            </code>
            , the HMAC-SHA256 of the raw body with this secret as key. Compute it over the exact
            bytes before parsing the JSON, and compare in constant time. The payload{' '}
            <code className="font-mono">id</code> stays the same when a delivery is sent again, so
            receivers can drop duplicates.
          </p>
          <CodeBlock
            title="Check a signature in a shell, with the body in body.json"
            code={`printf 'sha256=%s\\n' "$(openssl dgst -sha256 -hmac "$SECRET" -hex < body.json | sed 's/^.* //')"`}
            label="the verification command"
          />
        </div>
      </PanelBody>
    </Panel>
  )
}

function Deliveries({ webhook, counts }: { webhook: Webhook; counts: Record<string, number> }) {
  const [params] = useSearchParams()
  const page = intParam(params, 'page', 1)
  const deliveries = useDeliveries(webhook.id, page)
  const redeliver = useRedeliver()
  const settings = useSettings()
  const [open, setOpen] = useState<string | null>(null)
  const retention = settingDays(settings.data, 'webhooks.retentionDays')
  const selected = deliveries.data?.items.find((delivery) => delivery.id === open)

  return (
    <>
      <Panel aria-labelledby="deliveries-title">
        <PanelHeader title="Deliveries" titleId="deliveries-title">
          <div className="flex flex-wrap items-center gap-3">
            {!!retention && (
              <span className="text-xs text-muted-foreground">Kept {retention} days</span>
            )}
            <DeliveryCounts counts={counts} />
            <Button
              variant="ghost"
              size="sm"
              onClick={() => void deliveries.refetch()}
              disabled={deliveries.isFetching}
            >
              <RotateCw
                aria-hidden
                className={deliveries.isFetching ? 'motion-safe:animate-spin' : undefined}
              />
              Refresh
            </Button>
          </div>
        </PanelHeader>
        {deliveries.isPending ? (
          <PanelBody>
            <TableSkeleton rows={4} columns={6} />
          </PanelBody>
        ) : deliveries.isError ? (
          <PanelBody>
            <ErrorState error={deliveries.error} onRetry={() => void deliveries.refetch()} />
          </PanelBody>
        ) : deliveries.data.total === 0 ? (
          <PanelBody>
            <EmptyState title="No deliveries yet">
              Deliveries appear when one of its events happens.
            </EmptyState>
          </PanelBody>
        ) : (
          <>
            <CompactTable boxed={false}>
              <caption className="sr-only">Deliveries, newest first</caption>
              <TableHeader>
                <TableRow>
                  <TableHead scope="col">Time</TableHead>
                  <TableHead scope="col">Event</TableHead>
                  <TableHead scope="col">Package</TableHead>
                  <TableHead scope="col" className="text-right">
                    Attempt
                  </TableHead>
                  <TableHead scope="col">Status</TableHead>
                  <TableHead scope="col" className="text-right">
                    Response
                  </TableHead>
                  <TableHead scope="col" className="text-right">
                    Duration
                  </TableHead>
                  <TableHead scope="col">Error</TableHead>
                  <TableHead scope="col">
                    <span className="sr-only">Actions</span>
                  </TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {deliveries.data.items.map((delivery) => {
                  const expanded = open === delivery.id
                  return (
                    <TableRow key={delivery.id} data-expanded={expanded || undefined}>
                      <TableCell>
                        <button
                          type="button"
                          aria-expanded={expanded}
                          aria-controls={`payload-${delivery.id}`}
                          title={formatDateTime(delivery.createdAt)}
                          onClick={() => setOpen(expanded ? null : delivery.id)}
                          className="rounded-sm font-medium whitespace-nowrap text-primary hover:underline"
                        >
                          {formatRelative(delivery.createdAt)}
                          <span className="sr-only">
                            {expanded ? ': hide the payload' : ': show the payload'}
                          </span>
                        </button>
                      </TableCell>
                      <TableCell>
                        <Chip>{delivery.event}</Chip>
                      </TableCell>
                      <TableCell className="font-mono text-xs">
                        {delivery.package ? `${delivery.package} ${delivery.version ?? ''}` : '–'}
                      </TableCell>
                      <TableCell className="text-right tabular-nums">{delivery.attempt}</TableCell>
                      <TableCell>
                        <DeliveryStatusBadge status={delivery.status} />
                      </TableCell>
                      <TableCell className="text-right font-mono text-xs">
                        {delivery.response?.status ?? '–'}
                      </TableCell>
                      <TableCell className="text-right text-muted-foreground tabular-nums">
                        {duration(delivery)}
                      </TableCell>
                      <TableCell
                        className="max-w-64 truncate text-xs text-destructive"
                        title={delivery.error ?? undefined}
                      >
                        {delivery.error}
                      </TableCell>
                      <TableCell className="text-right">
                        <Button
                          variant="outline"
                          size="xs"
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
                  )
                })}
              </TableBody>
            </CompactTable>
            {deliveries.data.total > deliveries.data.size && (
              <div className="border-t px-3 py-2.5">
                <Pager
                  page={deliveries.data.page}
                  size={deliveries.data.size}
                  total={deliveries.data.total}
                  label="Delivery pages"
                />
              </div>
            )}
          </>
        )}
      </Panel>
      {selected && <DeliveryPayload webhook={webhook} delivery={selected} />}
    </>
  )
}

/** The request of a delivery as it was sent: its headers and its body. */
function DeliveryPayload({ webhook, delivery }: { webhook: Webhook; delivery: Delivery }) {
  const { config } = useSession()
  const path = (() => {
    try {
      const url = new URL(webhook.url)
      return `${url.pathname}${url.search}`
    } catch {
      return webhook.url
    }
  })()
  const headers = [
    `POST ${path}`,
    'Content-Type: application/json',
    `User-Agent: unpub/${config.version}`,
    `X-Unpub-Event: ${delivery.event}`,
    `X-Unpub-Delivery: ${delivery.id}`,
    'X-Unpub-Signature: sha256=<HMAC-SHA256 of the body>',
  ].join('\n')
  return (
    <Panel id={`payload-${delivery.id}`} aria-labelledby={`payload-${delivery.id}-title`}>
      <PanelHeader
        title={`Delivery ${delivery.id.slice(0, 8)} · payload`}
        titleId={`payload-${delivery.id}-title`}
      >
        <span className="flex items-center gap-2">
          <DeliveryStatusBadge status={delivery.status} />
          {delivery.status === 'pending' && delivery.nextAt && (
            <span className="text-xs text-muted-foreground">
              next attempt {formatRelative(delivery.nextAt)}
            </span>
          )}
        </span>
      </PanelHeader>
      <PanelBody className="grid gap-4 lg:grid-cols-[minmax(0,0.9fr)_minmax(0,1.1fr)]">
        <div className="grid content-start gap-4">
          <CodeBlock title="Request headers" code={headers} label="the request headers" />
          {delivery.response?.body && (
            <CodeBlock
              title={`Response body (start), HTTP ${delivery.response.status}`}
              code={delivery.response.body}
              label="the response body"
            />
          )}
        </div>
        <div className="grid content-start gap-2">
          <CodeBlock title="Body" code={pretty(delivery.payload)} label="the payload" />
          <p className="text-xs text-muted-foreground">
            Sent and signed as the compact form of this JSON. Event id{' '}
            <code className="font-mono">{delivery.eventId}</code>
            {delivery.redeliveryOf && (
              <>
                , a redelivery of <code className="font-mono">{delivery.redeliveryOf}</code>
              </>
            )}
            .
          </p>
        </div>
      </PanelBody>
    </Panel>
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
