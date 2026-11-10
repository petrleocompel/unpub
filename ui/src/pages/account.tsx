import { useId, useState, type FormEvent } from 'react'
import { KeyRound, Loader2, Plus, Trash2 } from 'lucide-react'
import { useSearchParams } from 'react-router'
import { ApiError, errorMessage } from '@/api/client'
import { useChangePassword, useCreateToken, useRevokeToken, useTokens } from '@/api/queries'
import type { Scope, Token, TokenCreated } from '@/api/types'
import { hostedUrl, useSession } from '@/auth/session'
import { RoleBadge, ScopeBadge } from '@/components/badges'
import { CodeBlock } from '@/components/copy-button'
import { ConfirmDialog } from '@/components/confirm-dialog'
import { Field, FormError, invalidField } from '@/components/form'
import { NativeSelect } from '@/components/native-select'
import { intParam, Pager } from '@/components/pager'
import { SecretBox } from '@/components/secret-box'
import { EmptyState, ErrorState, TableSkeleton } from '@/components/states'
import { DateTime, RelativeTime } from '@/components/time'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Checkbox } from '@/components/ui/checkbox'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table'
import { Page } from '@/layout/root'
import { toast } from '@/lib/toast'
import { useTitle } from '@/lib/use-title'

export const expiryOptions = [
  { value: '30d', label: '30 days' },
  { value: '90d', label: '90 days' },
  { value: '1y', label: '1 year' },
  { value: 'never', label: 'Never' },
]

export function AccountPage() {
  useTitle('Account')
  return (
    <Page>
      <div className="grid gap-6">
        <h1 className="text-2xl font-semibold">Account</h1>
        <Profile />
        <Tokens />
        <PasswordForm />
      </div>
    </Page>
  )
}

function Profile() {
  const { me } = useSession()
  if (!me) return null
  const user = me.user
  return (
    <Card>
      <CardHeader>
        <CardTitle>
          <h2>Profile</h2>
        </CardTitle>
      </CardHeader>
      <CardContent>
        <dl className="grid gap-x-6 gap-y-3 text-sm sm:grid-cols-[10rem_1fr]">
          <dt className="text-muted-foreground">Email</dt>
          <dd>{user.email}</dd>
          <dt className="text-muted-foreground">Display name</dt>
          <dd>{('displayName' in user && user.displayName) || '–'}</dd>
          <dt className="text-muted-foreground">Role</dt>
          <dd>
            <RoleBadge role={user.role} />
          </dd>
          <dt className="text-muted-foreground">Scopes of this session</dt>
          <dd className="flex gap-1.5">
            {me.scopes.map((scope) => (
              <ScopeBadge key={scope} scope={scope} />
            ))}
          </dd>
        </dl>
      </CardContent>
    </Card>
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
    <Card>
      <CardHeader>
        <CardTitle>
          <h2>Change password</h2>
        </CardTitle>
        <CardDescription>
          Your other sessions are logged out when the password changes.
        </CardDescription>
      </CardHeader>
      <CardContent>
        {isSession ? (
          <form onSubmit={submit} className="grid max-w-sm gap-4">
            {/* For password managers. */}
            <input type="text" autoComplete="username" hidden readOnly value="" />
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
            <Field id={`${id}-confirm`} label="Confirm the new password">
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
            <FormError id={`${id}-error`} message={error} />
            <div>
              <Button type="submit" disabled={change.isPending}>
                {change.isPending && <Loader2 aria-hidden className="animate-spin" />}
                Change password
              </Button>
            </div>
          </form>
        ) : (
          <p className="text-sm text-muted-foreground">Log in with your password to change it.</p>
        )}
      </CardContent>
    </Card>
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
    <Card>
      <CardHeader>
        <CardTitle>
          <h2>API tokens</h2>
        </CardTitle>
        <CardDescription>
          Tokens let <code className="font-mono">dart pub</code> and scripts act as you, limited to
          their scopes.
        </CardDescription>
      </CardHeader>
      <CardContent className="grid gap-6">
        {created && (
          <SecretBox
            title={`Token “${created.token.name}” created`}
            secret={created.secret}
            label="the token"
          >
            <p className="text-sm">Add it to the pub client, which asks for the token:</p>
            <CodeBlock code={`dart pub token add ${hostedUrl(config)}`} label="the token command" />
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
            <Table containerClassName="rounded-lg border" stickyFirstColumn>
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
                      className={inactive ? 'text-muted-foreground' : undefined}
                    >
                      <TableCell className="font-medium">
                        <div className="flex flex-wrap items-center gap-2">
                          {token.name}
                          {token.revokedAt && <Badge variant="outline">Revoked</Badge>}
                          {!token.revokedAt && expired && <Badge variant="outline">Expired</Badge>}
                        </div>
                      </TableCell>
                      <TableCell className="font-mono text-xs">{token.prefix}…</TableCell>
                      <TableCell>
                        <div className="flex gap-1">
                          {token.scopes.map((scope) => (
                            <ScopeBadge key={scope} scope={scope} />
                          ))}
                        </div>
                      </TableCell>
                      <TableCell>
                        <DateTime value={token.createdAt} date />
                      </TableCell>
                      <TableCell>
                        {token.lastUsedAt ? <RelativeTime value={token.lastUsedAt} /> : 'Never'}
                      </TableCell>
                      <TableCell>
                        {token.expiresAt ? <DateTime value={token.expiresAt} date /> : 'Never'}
                      </TableCell>
                      <TableCell className="text-right">
                        {!token.revokedAt && (
                          <Button
                            variant="ghost"
                            size="sm"
                            onClick={() => setRevoking(token)}
                            aria-label={`Revoke ${token.name}`}
                          >
                            <Trash2 aria-hidden />
                            Revoke
                          </Button>
                        )}
                      </TableCell>
                    </TableRow>
                  )
                })}
              </TableBody>
            </Table>
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
      </CardContent>
    </Card>
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
    <form
      onSubmit={submit}
      className="grid gap-4 rounded-lg border p-4"
      aria-labelledby={`${id}-title`}
    >
      <h3 id={`${id}-title`} className="font-semibold">
        Create a token
      </h3>
      <div className="grid gap-4 sm:grid-cols-[1fr_auto_auto] sm:items-end">
        <Field id={`${id}-name`} label="Name">
          <Input
            id={`${id}-name`}
            required
            value={name}
            placeholder="laptop, ci-read, …"
            onChange={(event) => setName(event.target.value)}
          />
        </Field>
        <fieldset className="grid gap-2">
          <legend className="mb-2 text-sm font-medium">Scopes</legend>
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
        <Field id={`${id}-expiry`} label="Expires after">
          <NativeSelect
            id={`${id}-expiry`}
            value={expiry}
            onChange={(event) => setExpiry(event.target.value)}
            className="w-32"
          >
            {expiryOptions.map((option) => (
              <option key={option.label} value={option.value}>
                {option.label}
              </option>
            ))}
          </NativeSelect>
        </Field>
      </div>
      {me?.user.role === 'reader' && (
        <p className="text-xs text-muted-foreground">
          As a reader you can create read tokens only.
        </p>
      )}
      <FormError id={`${id}-error`} message={create.error ? errorMessage(create.error) : null} />
      <div>
        <Button type="submit" disabled={create.isPending || chosen.length === 0}>
          {create.isPending ? (
            <Loader2 aria-hidden className="animate-spin" />
          ) : (
            <Plus aria-hidden />
          )}
          Create token
        </Button>
      </div>
    </form>
  )
}
