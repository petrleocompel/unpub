import { useId, useState, type FormEvent } from 'react'
import { Loader2, Plus, Webhook as WebhookIcon } from 'lucide-react'
import { Link, useSearchParams } from 'react-router'
import { errorMessage } from '@/api/client'
import { useCreateWebhook, useUpdateWebhook, useWebhooks } from '@/api/queries'
import { webhookEvents, type WebhookCreated, type WebhookEvent } from '@/api/types'
import { Chip, Dot } from '@/components/dashboard/panel'
import { Field, FormError } from '@/components/form'
import { intParam, Pager } from '@/components/pager'
import { SecretBox } from '@/components/secret-box'
import { EmptyState, ErrorState, ListSkeleton } from '@/components/states'
import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Checkbox } from '@/components/ui/checkbox'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Switch } from '@/components/ui/switch'
import { formatNumber } from '@/lib/format'
import { toast } from '@/lib/toast'
import { useTitle } from '@/lib/use-title'
import { AdminHeading } from './layout'

export function EventChips({ events }: { events: WebhookEvent[] }) {
  return (
    <ul className="flex flex-wrap gap-1" aria-label="Events">
      {events.map((event) => (
        <li key={event}>
          <Chip>{event}</Chip>
        </li>
      ))}
    </ul>
  )
}

/** The delivery counts of a webhook as three status badges. */
export function DeliveryCounts({ counts }: { counts: Partial<Record<string, number>> }) {
  return (
    <div className="flex flex-wrap gap-1.5">
      <Badge variant="success">
        <Dot tone="success" />
        {formatNumber(counts.succeeded ?? 0)} delivered
      </Badge>
      <Badge variant="warning">
        <Dot tone="warning" />
        {formatNumber(counts.pending ?? 0)} pending
      </Badge>
      <Badge variant="danger">
        <Dot tone="danger" />
        {formatNumber(counts.failed ?? 0)} failed
      </Badge>
    </div>
  )
}

export function WebhooksPage() {
  useTitle('Webhooks')
  const [params] = useSearchParams()
  const page = intParam(params, 'page', 1)
  const webhooks = useWebhooks(page)
  const [creating, setCreating] = useState(false)
  const [created, setCreated] = useState<WebhookCreated | null>(null)
  const update = useUpdateWebhook()

  return (
    <>
      <AdminHeading
        title="Webhooks"
        description={
          <>
            unpub POSTs a signed JSON event to each URL. Failed deliveries retry after 30 s, 2 min,
            10 min, then hourly, up to <span className="font-mono">webhooks.maxAttempts</span>{' '}
            attempts (5 by default).
          </>
        }
        actions={
          <Button size="sm" onClick={() => setCreating(true)}>
            <Plus aria-hidden />
            New webhook
          </Button>
        }
      />
      <div className="grid gap-4">
        {created && (
          <SecretBox
            title="Webhook created: its signing secret"
            secret={created.secret}
            label="the webhook secret"
          >
            <p className="text-sm">
              Verify the <code className="font-mono">X-Unpub-Signature</code> header with it.{' '}
              <Link
                to={`/admin/webhooks/${created.webhook.id}`}
                className="font-medium text-primary underline underline-offset-4"
              >
                Open the webhook
              </Link>
              .
            </p>
            <div>
              <Button variant="outline" size="sm" onClick={() => setCreated(null)}>
                I have copied it
              </Button>
            </div>
          </SecretBox>
        )}
        {webhooks.data && !webhooks.data.enabled && (
          <Alert variant="warning">
            <WebhookIcon aria-hidden />
            <AlertTitle>Deliveries are switched off</AlertTitle>
            <AlertDescription>
              <p>
                <code className="font-mono">webhooks.enabled</code> is false: no events are queued
                or sent.
              </p>
            </AlertDescription>
          </Alert>
        )}
        {webhooks.isPending ? (
          <ListSkeleton rows={3} label="Loading the webhooks" />
        ) : webhooks.isError ? (
          <ErrorState error={webhooks.error} onRetry={() => void webhooks.refetch()} />
        ) : webhooks.data.total === 0 ? (
          <EmptyState icon={WebhookIcon} title="No webhooks yet">
            Create one to receive a signed POST when a package is published, retracted or
            discontinued.
          </EmptyState>
        ) : (
          <>
            <ul aria-label="Webhooks" className="divide-y rounded-lg border bg-card">
              {webhooks.data.items.map((webhook) => (
                <li
                  key={webhook.id}
                  className="grid gap-x-6 gap-y-3 px-4 py-3.5 hover:bg-muted/60 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-center sm:px-5 sm:py-4"
                >
                  <div className="grid min-w-0 gap-1.5">
                    <div className="flex min-w-0 items-center gap-2">
                      <Link
                        to={`/admin/webhooks/${webhook.id}`}
                        className="truncate font-mono text-[0.8125rem] font-medium text-primary hover:underline"
                      >
                        {webhook.url}
                      </Link>
                      {!webhook.enabled && <Badge variant="outline">Paused</Badge>}
                    </div>
                    {webhook.description && (
                      <p className="truncate text-[0.8125rem] text-muted-foreground">
                        {webhook.description}
                      </p>
                    )}
                    <EventChips events={webhook.events} />
                  </div>
                  <div className="flex flex-wrap items-center gap-4 sm:justify-end">
                    <DeliveryCounts counts={webhook.deliveries} />
                    <div className="flex items-center gap-2 text-[0.8125rem]">
                      <Switch
                        id={`enabled-${webhook.id}`}
                        checked={webhook.enabled}
                        aria-label={`${webhook.enabled ? 'Disable' : 'Enable'} ${webhook.url}`}
                        disabled={update.isPending}
                        onCheckedChange={(enabled) =>
                          update.mutate(
                            { id: webhook.id, enabled },
                            {
                              onSuccess: () =>
                                toast.success(enabled ? 'Webhook enabled' : 'Webhook disabled'),
                              onError: (error) =>
                                toast.error('The webhook was not changed', errorMessage(error)),
                            },
                          )
                        }
                      />
                      <span aria-hidden className="hidden sm:inline">
                        Enabled
                      </span>
                    </div>
                  </div>
                </li>
              ))}
            </ul>
            <Pager
              page={webhooks.data.page}
              size={webhooks.data.size}
              total={webhooks.data.total}
              label="Webhook pages"
            />
          </>
        )}
      </div>
      <Dialog open={creating} onOpenChange={setCreating}>
        <DialogContent>
          {creating && (
            <CreateWebhookForm
              onDone={(result) => {
                setCreating(false)
                if (result) setCreated(result)
              }}
            />
          )}
        </DialogContent>
      </Dialog>
    </>
  )
}

/** URL, events and description; shared by the create dialog and the edit form. */
export function WebhookFields({
  idPrefix,
  url,
  setUrl,
  events,
  setEvents,
  description,
  setDescription,
}: {
  idPrefix: string
  url: string
  setUrl: (value: string) => void
  events: WebhookEvent[]
  setEvents: (value: WebhookEvent[]) => void
  description: string
  setDescription: (value: string) => void
}) {
  return (
    <>
      <Field
        id={`${idPrefix}-url`}
        label="Payload URL"
        hint="https, or http when webhooks.allowHttp is set."
      >
        <Input
          id={`${idPrefix}-url`}
          type="url"
          required
          placeholder="https://ci.company.example/hooks/unpub"
          value={url}
          aria-describedby={`${idPrefix}-url-hint`}
          onChange={(event) => setUrl(event.target.value)}
          className="font-mono text-[0.8125rem] md:text-[0.8125rem]"
        />
      </Field>
      <Field
        id={`${idPrefix}-description`}
        label={
          <>
            Description <span className="font-normal text-muted-foreground">(optional)</span>
          </>
        }
      >
        <Input
          id={`${idPrefix}-description`}
          maxLength={200}
          value={description}
          onChange={(event) => setDescription(event.target.value)}
        />
      </Field>
      <fieldset className="grid gap-2">
        <legend className="mb-2 text-sm font-medium">Events</legend>
        <div className="grid gap-2 sm:grid-cols-2">
          {webhookEvents.map((event) => (
            <div key={event} className="flex items-center gap-2">
              <Checkbox
                id={`${idPrefix}-event-${event}`}
                checked={events.includes(event)}
                onCheckedChange={(checked) =>
                  setEvents(
                    checked ? [...events, event] : events.filter((value) => value !== event),
                  )
                }
              />
              <Label
                htmlFor={`${idPrefix}-event-${event}`}
                className="font-mono text-xs font-normal"
              >
                {event}
              </Label>
            </div>
          ))}
        </div>
      </fieldset>
    </>
  )
}

function CreateWebhookForm({ onDone }: { onDone: (created?: WebhookCreated) => void }) {
  const id = useId()
  const create = useCreateWebhook()
  const [url, setUrl] = useState('')
  const [events, setEvents] = useState<WebhookEvent[]>(['package.published'])
  const [description, setDescription] = useState('')

  const submit = (event: FormEvent) => {
    event.preventDefault()
    create.mutate(
      { url: url.trim(), events, description: description.trim() || undefined },
      {
        onSuccess: (result) => {
          toast.success('Webhook created', 'Copy its secret now, it is shown once.')
          onDone(result)
        },
      },
    )
  }

  return (
    <form onSubmit={submit} className="grid gap-4">
      <DialogHeader>
        <DialogTitle>New webhook</DialogTitle>
        <DialogDescription>A signing secret is created with it and shown once.</DialogDescription>
      </DialogHeader>
      <WebhookFields
        idPrefix={id}
        url={url}
        setUrl={setUrl}
        events={events}
        setEvents={setEvents}
        description={description}
        setDescription={setDescription}
      />
      <FormError id={`${id}-error`} message={create.error ? errorMessage(create.error) : null} />
      <DialogFooter>
        <Button type="button" variant="outline" onClick={() => onDone()}>
          Cancel
        </Button>
        <Button type="submit" disabled={create.isPending || events.length === 0}>
          {create.isPending && <Loader2 aria-hidden className="animate-spin" />}
          Create webhook
        </Button>
      </DialogFooter>
    </form>
  )
}
