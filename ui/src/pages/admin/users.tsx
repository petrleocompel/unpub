import { useId, useState, type FormEvent } from 'react'
import {
  KeyRound,
  Loader2,
  MoreHorizontal,
  Plus,
  Search,
  ShieldCheck,
  UserCheck,
  UserX,
} from 'lucide-react'
import { useSearchParams } from 'react-router'
import { ApiError, errorMessage } from '@/api/client'
import { useCreateUser, useSetUserPassword, useUpdateUser, useUsers } from '@/api/queries'
import { roles, type Role, type User } from '@/api/types'
import { useSession } from '@/auth/session'
import { DisabledBadge, RoleBadge } from '@/components/badges'
import { ConfirmDialog } from '@/components/confirm-dialog'
import { Field, FormError } from '@/components/form'
import { NativeSelect } from '@/components/native-select'
import { intParam, Pager } from '@/components/pager'
import { EmptyState, ErrorState, TableSkeleton } from '@/components/states'
import { DateTime, RelativeTime } from '@/components/time'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu'
import { Input } from '@/components/ui/input'
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table'
import { toast } from '@/lib/toast'
import { useDebouncedParam } from '@/lib/use-debounced-param'
import { useTitle } from '@/lib/use-title'
import { AdminHeading } from './layout'

/** The message for a failed change of a user, explaining the admin guard. */
export function userChangeError(error: unknown) {
  if (error instanceof ApiError && error.code === 'last_admin') {
    return `${error.message} Make another user an administrator first.`
  }
  return errorMessage(error)
}

export function UsersPage() {
  useTitle('Users')
  const [params] = useSearchParams()
  const [text, setText, q] = useDebouncedParam('q')
  const page = intParam(params, 'page', 1)
  const users = useUsers(q, page)
  const [creating, setCreating] = useState(false)
  const [passwordFor, setPasswordFor] = useState<User | null>(null)
  const [toggling, setToggling] = useState<User | null>(null)
  const [roleFor, setRoleFor] = useState<User | null>(null)
  const update = useUpdateUser()
  const { me } = useSession()

  return (
    <>
      <AdminHeading
        title="Users"
        description="There is no self sign-up or invitation email: create the account and hand over the password."
        actions={
          <Button onClick={() => setCreating(true)}>
            <Plus aria-hidden />
            Create user
          </Button>
        }
      />
      <div className="grid gap-4">
        <div className="relative max-w-sm">
          <label htmlFor="user-search" className="sr-only">
            Search users
          </label>
          <Search
            aria-hidden
            className="pointer-events-none absolute top-1/2 left-2.5 size-4 -translate-y-1/2 text-muted-foreground"
          />
          <Input
            id="user-search"
            type="search"
            placeholder="Search by email or name"
            className="pl-8"
            value={text}
            onChange={(event) => setText(event.target.value)}
          />
        </div>
        {users.isPending ? (
          <TableSkeleton columns={6} />
        ) : users.isError ? (
          <ErrorState error={users.error} onRetry={() => void users.refetch()} />
        ) : users.data.total === 0 ? (
          <EmptyState title={q ? 'No users match' : 'No users yet'}>
            {q ? (
              <>
                Nothing matches <q>{q}</q>.
              </>
            ) : (
              'Create the first user.'
            )}
          </EmptyState>
        ) : (
          <>
            <Table containerClassName="rounded-lg border" stickyFirstColumn>
              <caption className="sr-only">Users, by email</caption>
              <TableHeader>
                <TableRow>
                  <TableHead scope="col">Email</TableHead>
                  <TableHead scope="col">Display name</TableHead>
                  <TableHead scope="col">Role</TableHead>
                  <TableHead scope="col">Status</TableHead>
                  <TableHead scope="col">Created</TableHead>
                  <TableHead scope="col">Last login</TableHead>
                  <TableHead scope="col">
                    <span className="sr-only">Actions</span>
                  </TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {users.data.items.map((user) => (
                  <TableRow key={user.id}>
                    <TableCell className="font-medium">
                      {user.email}
                      {user.id === me?.user.id && (
                        <span className="ml-2 text-xs text-muted-foreground">(you)</span>
                      )}
                    </TableCell>
                    <TableCell>{user.displayName || '–'}</TableCell>
                    <TableCell>
                      <RoleBadge role={user.role} />
                    </TableCell>
                    <TableCell>
                      <div className="flex flex-wrap gap-1">
                        {user.disabled ? (
                          <DisabledBadge />
                        ) : (
                          <Badge variant="outline">Enabled</Badge>
                        )}
                        {!user.hasPassword && <Badge variant="outline">No password</Badge>}
                      </div>
                    </TableCell>
                    <TableCell>
                      <DateTime value={user.createdAt} date />
                    </TableCell>
                    <TableCell>
                      {user.lastLoginAt ? <RelativeTime value={user.lastLoginAt} /> : 'Never'}
                    </TableCell>
                    <TableCell className="text-right">
                      <DropdownMenu modal={false}>
                        <DropdownMenuTrigger asChild>
                          <Button
                            variant="ghost"
                            size="icon-sm"
                            aria-label={`Actions for ${user.email}`}
                          >
                            <MoreHorizontal aria-hidden />
                          </Button>
                        </DropdownMenuTrigger>
                        <DropdownMenuContent align="end" className="w-52">
                          <DropdownMenuLabel className="truncate text-xs font-normal text-muted-foreground">
                            {user.email}
                          </DropdownMenuLabel>
                          <DropdownMenuItem onSelect={() => setRoleFor(user)}>
                            <ShieldCheck aria-hidden />
                            Change role…
                          </DropdownMenuItem>
                          <DropdownMenuItem onSelect={() => setPasswordFor(user)}>
                            <KeyRound aria-hidden />
                            Set password…
                          </DropdownMenuItem>
                          <DropdownMenuSeparator />
                          <DropdownMenuItem
                            variant={user.disabled ? 'default' : 'destructive'}
                            onSelect={() => setToggling(user)}
                          >
                            {user.disabled ? <UserCheck aria-hidden /> : <UserX aria-hidden />}
                            {user.disabled ? 'Enable…' : 'Disable…'}
                          </DropdownMenuItem>
                        </DropdownMenuContent>
                      </DropdownMenu>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
            <Pager
              page={users.data.page}
              size={users.data.size}
              total={users.data.total}
              label="User pages"
            />
          </>
        )}
      </div>
      <CreateUserDialog open={creating} onOpenChange={setCreating} />
      <SetPasswordDialog user={passwordFor} onClose={() => setPasswordFor(null)} />
      <RoleDialog user={roleFor} onClose={() => setRoleFor(null)} />
      <ConfirmDialog
        open={toggling !== null}
        onOpenChange={(open) => !open && setToggling(null)}
        title={
          toggling?.disabled ? `Enable ${toggling.email}?` : `Disable ${toggling?.email ?? ''}?`
        }
        description={
          toggling?.disabled
            ? 'They can log in again and their tokens work again.'
            : 'They are logged out, and their tokens stop working until enabled again. The last administrator cannot be disabled.'
        }
        confirmLabel={toggling?.disabled ? 'Enable user' : 'Disable user'}
        destructive={!toggling?.disabled}
        onConfirm={async () => {
          if (!toggling) return
          try {
            await update.mutateAsync({ id: toggling.id, disabled: !toggling.disabled })
          } catch (error) {
            throw new Error(userChangeError(error))
          }
          toast.success(
            toggling.disabled ? `Enabled ${toggling.email}` : `Disabled ${toggling.email}`,
          )
        }}
      />
    </>
  )
}

function CreateUserDialog({
  open,
  onOpenChange,
}: {
  open: boolean
  onOpenChange: (open: boolean) => void
}) {
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>{open && <CreateUserForm onDone={() => onOpenChange(false)} />}</DialogContent>
    </Dialog>
  )
}

function CreateUserForm({ onDone }: { onDone: () => void }) {
  const id = useId()
  const create = useCreateUser()
  const [email, setEmail] = useState('')
  const [displayName, setDisplayName] = useState('')
  const [role, setRole] = useState<Role>('publisher')
  const [password, setPassword] = useState('')

  const submit = (event: FormEvent) => {
    event.preventDefault()
    create.mutate(
      {
        email: email.trim(),
        role,
        displayName: displayName.trim() || undefined,
        password: password || undefined,
      },
      {
        onSuccess: ({ user }) => {
          toast.success(
            `Created ${user.email}`,
            password ? 'Hand the password over to them.' : 'Set a password before they can log in.',
          )
          onDone()
        },
      },
    )
  }

  return (
    <form onSubmit={submit} className="grid gap-4">
      <DialogHeader>
        <DialogTitle>Create user</DialogTitle>
        <DialogDescription>
          No email is sent. Give the user their password yourself.
        </DialogDescription>
      </DialogHeader>
      <Field id={`${id}-email`} label="Email">
        <Input
          id={`${id}-email`}
          type="email"
          required
          autoComplete="off"
          value={email}
          onChange={(event) => setEmail(event.target.value)}
        />
      </Field>
      <Field id={`${id}-name`} label="Display name (optional)">
        <Input
          id={`${id}-name`}
          value={displayName}
          onChange={(event) => setDisplayName(event.target.value)}
        />
      </Field>
      <Field id={`${id}-role`} label="Role">
        <NativeSelect
          id={`${id}-role`}
          value={role}
          onChange={(event) => setRole(event.target.value as Role)}
          className="w-full"
        >
          {roles.map((value) => (
            <option key={value} value={value}>
              {value}
            </option>
          ))}
        </NativeSelect>
      </Field>
      <Field
        id={`${id}-password`}
        label="Initial password (optional)"
        hint="At least 8 characters. Without one the account is a placeholder that cannot log in until you set it."
      >
        <Input
          id={`${id}-password`}
          type="password"
          autoComplete="new-password"
          minLength={8}
          value={password}
          aria-describedby={`${id}-password-hint`}
          onChange={(event) => setPassword(event.target.value)}
        />
      </Field>
      <FormError id={`${id}-error`} message={create.error ? errorMessage(create.error) : null} />
      <DialogFooter>
        <Button type="button" variant="outline" onClick={onDone}>
          Cancel
        </Button>
        <Button type="submit" disabled={create.isPending}>
          {create.isPending && <Loader2 aria-hidden className="animate-spin" />}
          Create user
        </Button>
      </DialogFooter>
    </form>
  )
}

function SetPasswordDialog({ user, onClose }: { user: User | null; onClose: () => void }) {
  return (
    <Dialog open={user !== null} onOpenChange={(open) => !open && onClose()}>
      <DialogContent>{user && <SetPasswordForm user={user} onDone={onClose} />}</DialogContent>
    </Dialog>
  )
}

function SetPasswordForm({ user, onDone }: { user: User; onDone: () => void }) {
  const id = useId()
  const set = useSetUserPassword()
  const [password, setPassword] = useState('')
  return (
    <form
      className="grid gap-4"
      onSubmit={(event) => {
        event.preventDefault()
        set.mutate(
          { id: user.id, password },
          {
            onSuccess: () => {
              toast.success(
                `Password set for ${user.email}`,
                'Their sessions have been logged out.',
              )
              onDone()
            },
          },
        )
      }}
    >
      <DialogHeader>
        <DialogTitle>Set the password of {user.email}</DialogTitle>
        <DialogDescription>
          Their sessions end. Hand the new password over to them.
        </DialogDescription>
      </DialogHeader>
      <Field id={`${id}-password`} label="New password" hint="At least 8 characters.">
        <Input
          id={`${id}-password`}
          type="password"
          autoComplete="new-password"
          required
          minLength={8}
          value={password}
          aria-describedby={`${id}-password-hint`}
          onChange={(event) => setPassword(event.target.value)}
        />
      </Field>
      <FormError id={`${id}-error`} message={set.error ? errorMessage(set.error) : null} />
      <DialogFooter>
        <Button type="button" variant="outline" onClick={onDone}>
          Cancel
        </Button>
        <Button type="submit" disabled={set.isPending}>
          {set.isPending && <Loader2 aria-hidden className="animate-spin" />}
          Set password
        </Button>
      </DialogFooter>
    </form>
  )
}

function RoleDialog({ user, onClose }: { user: User | null; onClose: () => void }) {
  const id = useId()
  const [role, setRole] = useState<Role>(user?.role ?? 'publisher')
  const [shown, setShown] = useState(user)
  if (user !== shown) {
    setShown(user)
    if (user) setRole(user.role)
  }
  const update = useUpdateUser()
  return (
    <ConfirmDialog
      open={user !== null}
      onOpenChange={(open) => !open && onClose()}
      title={`Change the role of ${user?.email ?? ''}`}
      description="Administrators may do everything, publishers publish and manage their packages, readers only read."
      confirmLabel="Change role"
      onConfirm={async () => {
        if (!user || role === user.role) return
        try {
          await update.mutateAsync({ id: user.id, role })
        } catch (error) {
          throw new Error(userChangeError(error))
        }
        toast.success(`${user.email} is now ${role === 'admin' ? 'an' : 'a'} ${role}`)
      }}
    >
      <Field id={`${id}-role`} label="Role">
        <NativeSelect
          id={`${id}-role`}
          value={role}
          onChange={(event) => setRole(event.target.value as Role)}
          className="w-full"
        >
          {roles.map((value) => (
            <option key={value} value={value}>
              {value}
            </option>
          ))}
        </NativeSelect>
      </Field>
    </ConfirmDialog>
  )
}
