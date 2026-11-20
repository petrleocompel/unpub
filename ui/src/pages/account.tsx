import { useId, useState, type FormEvent } from 'react'
import { Ban, Clock, Info, KeyRound, Loader2, Lock, Plus, User } from 'lucide-react'
import { useLocation, useSearchParams } from 'react-router'
import { ApiError, errorMessage } from '@/api/client'
import { useChangePassword, useCreateToken, useRevokeToken, useTokens } from '@/api/queries'
import type { Scope, Token, TokenCreated } from '@/api/types'
import { hostedUrl, useSession } from '@/auth/session'
import { Initials } from '@/components/avatar'
import { RoleBadge, ScopeBadge } from '@/components/badges'
import { CodeBlock } from '@/components/copy-button'
import { ConfirmDialog } from '@/components/confirm-dialog'
import { CompactTable } from '@/components/dashboard/compact-table'
import { Panel, PanelBody, PanelFooter, PanelHeader } from '@/components/dashboard/panel'
import { Segmented } from '@/components/dashboard/segmented'
import {
  DashboardHeading,
  DashboardShell,
  type DashboardSection,
} from '@/components/dashboard/shell'
import { Field, FormError, invalidField } from '@/components/form'
import { intParam, Pager } from '@/components/pager'
import { SecretBox } from '@/components/secret-box'
import { EmptyState, ErrorState, TableSkeleton } from '@/components/states'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Checkbox } from '@/components/ui/checkbox'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { formatDate, formatRelative } from '@/lib/format'
import { toast } from '@/lib/toast'
import { useTitle } from '@/lib/use-title'

export const expiryOptions = [
  { value: '30d', label: '30 d' },
  { value: '90d', label: '90 d' },
  { value: '1y', label: '1 y' },
  { value: 'never', label: 'Never' },
]

const sectionIds = ['profile', 'password', 'tokens'] as const

export function AccountPage() {
  useTitle('Account')
  const { hash } = useLocation()
  const shown = sectionIds.find((id) => hash === `#${id}`) ?? 'profile'
  const sections: DashboardSection[] = [
    { hash: 'profile', label: 'Profile', icon: User },
    { hash: 'password', label: 'Password', icon: Lock },
    { hash: 'tokens', label: 'API tokens', icon: KeyRound },
  ].map((section) => ({ ...section, current: section.hash === shown }))
  return (
    <DashboardShell label="Account" sections={sections} mainClassName="max-w-[68.75rem]">
      <DashboardHeading
        title="Account"
        description={
          <>
            Your profile, your password and the tokens <InlineCode>dart pub</InlineCode> and CI use.
          </>
        }
      />
      <div className="grid gap-6">
        <Profile />
        <PasswordForm />
        <Tokens />
      </div>
    </DashboardShell>
  )
}

function InlineCode({ children }: { children: React.ReactNode }) {
  return (
    <code className="rounded-sm border bg-muted px-1 py-px font-mono text-[0.75rem] text-foreground">
      {children}
    </code>
  )
}

function Profile() {
  const { me } = useSession()
  if (!me) return null
  const user = me.user
  const displayName = 'displayName' in user ? user.displayName : null
  return (
    <Panel id="profile" aria-labelledby="profile-title" className="scroll-mt-20">
      <PanelHeader title="Profile" titleId="profile-title" />
      <PanelBody className="flex flex-wrap items-start gap-6">
        <Initials email={user.email} size="lg" />
        <dl className="grid max-w-160 grow grid-cols-1 gap-x-4 gap-y-0.5 text-[0.8125rem] sm:grid-cols-[11.25rem_minmax(0,1fr)] sm:gap-y-2.5 [&>dd]:mb-2.5 sm:[&>dd]:mb-0">
          <dt className="text-muted-foreground">Email</dt>
          <dd className="font-medium break-all">{user.email}</dd>
          <dt className="text-muted-foreground">Display name</dt>
          <dd>{displayName || '–'}</dd>
          <dt className="text-muted-foreground">Role</dt>
          <dd>
            <RoleBadge role={user.role} />
          </dd>
          <dt className="text-muted-foreground">This session</dt>
          <dd className="flex flex-wrap items-center gap-2">
            {me.scopes.map((scope) => (
              <ScopeBadge key={scope} scope={scope} />
            ))}
          </dd>
        </dl>
      </PanelBody>
    </Panel>
  )
}

function PasswordForm() {
  const id = useId()
  const change = useChangePassword()
  const { isSession } = useSession()
  const [current, setCurrent] = useState('')
  const [next, setNext] = useState('')
  const [confirm, setConfirm] = useState('')
  const [mismatch, setMismatch] = useState(false)

  const submit = (event: FormEvent) => {
    event.preventDefault()
    if (next !== confirm) {
      setMismatch(true)
      return
    }
    setMismatch(false)
    change.mutate(
      { currentPassword: current, newPassword: next },
      {
        onSuccess: () => {
          toast.success('Password changed', 'Your other sessions have been logged out.')
          setCurrent('')
          setNext('')
          setConfirm('')
        },
      },
    )
  }

  const wrongCurrent =
    !mismatch && change.error instanceof ApiError && change.error.code === 'invalid_credentials'
  const error = mismatch
    ? 'The new passwords do not match.'
    : wrongCurrent
      ? 'The current password is wrong.'
      : change.error
        ? errorMessage(change.error)
        : null

  return (
    <Panel id="password" aria-labelledby="password-title" className="scroll-mt-20">
      <PanelHeader title="Change password" titleId="password-title" />
      {isSession ? (
        <form onSubmit={submit}>
          <PanelBody className="grid gap-4">
            {/* For password managers. */}
            <input type="text" autoComplete="username" hidden readOnly value="" />
            <div className="grid gap-4 md:grid-cols-3">
              <Field id={`${id}-current`} label="Current password">
                <Input
                  id={`${id}-current`}
                  type="password"
                  autoComplete="current-password"
                  required
                  value={current}
                  {...invalidField(`${id}-error`, wrongCurrent)}
                  onChange={(event) => setCurrent(event.target.value)}
                />
              </Field>
              <Field id={`${id}-new`} label="New password" hint="At least 8 characters.">
                <Input
                  id={`${id}-new`}
                  type="password"
                  autoComplete="new-password"
                  minLength={8}
                  required
                  value={next}
                  aria-describedby={`${id}-new-hint`}
                  onChange={(event) => setNext(event.target.value)}
                />
              </Field>
              <Field id={`${id}-confirm`} label="Repeat new password">
                <Input
                  id={`${id}-confirm`}
                  type="password"
                  autoComplete="new-password"
                  minLength={8}
                  required
                  value={confirm}
                  {...invalidField(`${id}-error`, mismatch)}
                  onChange={(event) => setConfirm(event.target.value)}
                />
              </Field>
            </div>
            <FormError id={`${id}-error`} message={error} />
          </PanelBody>
          <PanelFooter className="flex-nowrap justify-between">
            <p className="flex min-w-0 items-center gap-1 text-xs text-muted-foreground">
              <Info aria-hidden className="size-3 shrink-0" />
              Saving logs out your other sessions.
            </p>
            <Button type="submit" size="sm" className="shrink-0" disabled={change.isPending}>
              {change.isPending && <Loader2 aria-hidden className="animate-spin" />}
              Change password
            </Button>
          </PanelFooter>
        </form>
      ) : (
        <PanelBody>
          <p className="text-sm text-muted-foreground">Log in with your password to change it.</p>
        </PanelBody>
      )}
    </Panel>
  )
}

function Tokens() {
  const [params] = useSearchParams()
  const page = intParam(params, 'page', 1)
  const tokens = useTokens(page)
  const [created, setCreated] = useState<TokenCreated | null>(null)
  const [revoking, setRevoking] = useState<Token | null>(null)
  const revoke = useRevokeToken()
  const { config } = useSession()
  const [now] = useState(() => Date.now())

  return (
    <Panel id="tokens" aria-labelledby="tokens-title" className="scroll-mt-20">
      <PanelHeader
        title="API tokens"
        titleId="tokens-title"
        description={
          <>
            For <InlineCode>dart pub</InlineCode>, CI and scripts. A token has your role at most.
          </>
        }
      />
      <PanelBody className="grid gap-5">
        {created && (
          <SecretBox
            title={`Token “${created.token.name}” created`}
            secret={created.secret}
            label="the token"
          >
            <p className="text-sm">
              Then tell <InlineCode>dart pub</InlineCode> about it and paste the token when asked:
            </p>
            <CodeBlock
              code={`dart pub token add ${hostedUrl(config)}`}
              label="the token command"
              prompt
            />
            <div>
              <Button variant="outline" size="sm" onClick={() => setCreated(null)}>
                I have copied it
              </Button>
            </div>
          </SecretBox>
        )}
        <CreateTokenForm onCreated={setCreated} />
        {tokens.isPending ? (
          <TableSkeleton rows={3} columns={5} />
        ) : tokens.isError ? (
          <ErrorState error={tokens.error} onRetry={() => void tokens.refetch()} />
        ) : tokens.data.total === 0 ? (
          <EmptyState icon={KeyRound} title="No tokens yet">
            Create one above to publish with <code className="font-mono">dart pub</code> or read
            from CI.
          </EmptyState>
        ) : (
          <div className="grid gap-3">
            <CompactTable>
              <caption className="sr-only">Your API tokens, newest first</caption>
              <TableHeader>
                <TableRow>
                  <TableHead scope="col">Name</TableHead>
                  <TableHead scope="col">Prefix</TableHead>
                  <TableHead scope="col">Scopes</TableHead>
                  <TableHead scope="col">Created</TableHead>
                  <TableHead scope="col">Last used</TableHead>
                  <TableHead scope="col">Expires</TableHead>
                  <TableHead scope="col">
                    <span className="sr-only">Actions</span>
                  </TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {tokens.data.items.map((token) => {
                  const expired = !!token.expiresAt && new Date(token.expiresAt).getTime() < now
                  const inactive = !!token.revokedAt || expired
                  return (
                    <TableRow
                      key={token.id}
                      data-muted={inactive || undefined}
                      data-expanded={token.id === created?.token.id || undefined}
                    >
                      <TableCell className="font-medium">{token.name}</TableCell>
                      <TableCell className="font-mono text-xs text-muted-foreground">
                        {token.prefix}…
                      </TableCell>
                      <TableCell>
                        <div className="flex gap-1">
                          {token.scopes.map((scope) => (
                            <ScopeBadge key={scope} scope={scope} />
                          ))}
                        </div>
                      </TableCell>
                      <TableCell>
                        <When value={token.createdAt} now={now} />
                      </TableCell>
                      <TableCell>
                        {token.lastUsedAt ? (
                          <When value={token.lastUsedAt} now={now} />
                        ) : (
                          <span className="text-muted-foreground">never</span>
                        )}
                      </TableCell>
                      <TableCell>
                        {token.revokedAt ? (
                          <Badge variant="outline">
                            <Ban aria-hidden />
                            Revoked
                          </Badge>
                        ) : expired ? (
                          <Badge variant="outline">
                            <Clock aria-hidden />
                            Expired
                          </Badge>
                        ) : token.expiresAt ? (
                          <When value={token.expiresAt} now={now} />
                        ) : (
                          <span className="text-muted-foreground">never</span>
                        )}
                      </TableCell>
                      <TableCell className="text-right">
                        {!token.revokedAt && (
                          <Button
                            variant="destructive-outline"
                            size="xs"
                            onClick={() => setRevoking(token)}
                            aria-label={`Revoke ${token.name}`}
                          >
                            Revoke
                          </Button>
                        )}
                      </TableCell>
                    </TableRow>
                  )
                })}
              </TableBody>
            </CompactTable>
            <Pager
              page={tokens.data.page}
              size={tokens.data.size}
              total={tokens.data.total}
              label="Token pages"
            />
          </div>
        )}
        <ConfirmDialog
          open={revoking !== null}
          onOpenChange={(open) => !open && setRevoking(null)}
          title={`Revoke “${revoking?.name ?? ''}”?`}
          description="Anything using this token stops working at once. This cannot be undone."
          confirmLabel="Revoke token"
          destructive
          onConfirm={async () => {
            if (!revoking) return
            await revoke.mutateAsync(revoking.id)
            toast.success(`Revoked ${revoking.name}`)
          }}
        />
      </PanelBody>
    </Panel>
  )
}

/** A time as "3 days ago" or "in 90 days", with the date in its title. */
function When({ value, now }: { value: string; now: number }) {
  return (
    <time dateTime={value} title={formatDate(value)} className="whitespace-nowrap">
      {formatRelative(value, now)}
    </time>
  )
}

function CreateTokenForm({ onCreated }: { onCreated: (created: TokenCreated) => void }) {
  const id = useId()
  const { me } = useSession()
  const create = useCreateToken()
  const allowed: Scope[] =
    me?.user.role === 'reader'
      ? ['read']
      : (me?.scopes ?? ['read']).filter((s) => s === 'read' || s === 'publish')
  const [name, setName] = useState('')
  const [chosen, setChosen] = useState<Scope[]>(allowed)
  const [expiry, setExpiry] = useState('90d')

  const submit = (event: FormEvent) => {
    event.preventDefault()
    create.mutate(
      { name: name.trim(), scopes: chosen, expiresIn: expiry || undefined },
      {
        onSuccess: (result) => {
          onCreated(result)
          setName('')
          toast.success('Token created', 'Copy the secret now, it is shown once.')
        },
      },
    )
  }

  return (
    <form onSubmit={submit} className="grid gap-3" aria-label="New token">
      <div className="grid gap-4 md:grid-cols-[minmax(0,1.2fr)_auto_auto_auto] md:items-end">
        <Field id={`${id}-name`} label="Name">
          <Input
            id={`${id}-name`}
            required
            value={name}
            placeholder="e.g. github-actions"
            onChange={(event) => setName(event.target.value)}
          />
        </Field>
        <fieldset className="grid gap-2">
          <legend className="mb-2 text-sm leading-none font-medium">Scopes</legend>
          <div className="flex h-9 items-center gap-4">
            {(['read', 'publish'] as const).map((scope) => (
              <div key={scope} className="flex items-center gap-2">
                <Checkbox
                  id={`${id}-scope-${scope}`}
                  checked={chosen.includes(scope)}
                  disabled={!allowed.includes(scope)}
                  onCheckedChange={(checked) =>
                    setChosen((current) =>
                      checked
                        ? [...new Set([...current, scope])]
                        : current.filter((s) => s !== scope),
                    )
                  }
                />
                <Label htmlFor={`${id}-scope-${scope}`} className="font-mono font-normal">
                  {scope}
                </Label>
              </div>
            ))}
          </div>
        </fieldset>
        <Segmented
          label="Expires"
          value={expiry}
          options={expiryOptions}
          onChange={setExpiry}
          className="[&_button]:flex-1 [&>[role=group]]:w-full md:[&>[role=group]]:w-fit"
        />
        <Button type="submit" disabled={create.isPending || chosen.length === 0}>
          {create.isPending ? (
            <Loader2 aria-hidden className="animate-spin" />
          ) : (
            <Plus aria-hidden />
          )}
          Create token
        </Button>
      </div>
      {me?.user.role === 'reader' && (
        <p className="text-xs text-muted-foreground">
          As a reader you can create read tokens only.
        </p>
      )}
      <FormError id={`${id}-error`} message={create.error ? errorMessage(create.error) : null} />
    </form>
  )
}
