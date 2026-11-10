import { useId, useState, type FormEvent } from 'react'
import { Loader2, Trash2, UserPlus } from 'lucide-react'
import { errorMessage } from '@/api/client'
import {
  useAddUploader,
  useDeletePackage,
  useDeleteVersion,
  useDiscontinue,
  useRemoveUploader,
  useRetract,
  useTransferOwnership,
} from '@/api/queries'
import type { Package } from '@/api/types'
import { ConfirmDialog } from '@/components/confirm-dialog'
import { Field, FormError } from '@/components/form'
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
import { toast } from '@/lib/toast'

type Open = { open: boolean; onOpenChange: (open: boolean) => void }

export function RetractDialog({
  name,
  version,
  retracted,
  ...open
}: Open & { name: string; version: string; retracted: boolean }) {
  const retract = useRetract()
  return (
    <ConfirmDialog
      {...open}
      title={retracted ? `Restore ${name} ${version}?` : `Retract ${name} ${version}?`}
      description={
        retracted
          ? 'The version becomes a candidate for resolution again.'
          : 'pub will no longer pick this version for new resolutions. Existing lock files keep working. You can restore it later.'
      }
      confirmLabel={retracted ? 'Restore version' : 'Retract version'}
      destructive={!retracted}
      onConfirm={async () => {
        await retract.mutateAsync({ name, version, retract: !retracted })
        toast.success(retracted ? `Restored ${version}` : `Retracted ${version}`)
      }}
    />
  )
}

export function DiscontinueDialog({ pkg, ...open }: Open & { pkg: Package }) {
  return (
    <Dialog {...open}>
      <DialogContent>
        {open.open && <DiscontinueForm pkg={pkg} onDone={() => open.onOpenChange(false)} />}
      </DialogContent>
    </Dialog>
  )
}

export function DiscontinueForm({ pkg, onDone }: { pkg: Package; onDone?: () => void }) {
  const id = useId()
  const discontinue = useDiscontinue()
  const inDialog = !!onDone
  // A dialog opens to change the state, the form of the admin page shows it.
  const [discontinued, setDiscontinued] = useState(
    inDialog ? !pkg.isDiscontinued : pkg.isDiscontinued,
  )
  const [replacedBy, setReplacedBy] = useState(pkg.replacedBy ?? '')

  const submit = (event: FormEvent) => {
    event.preventDefault()
    discontinue.mutate(
      { name: pkg.name, isDiscontinued: discontinued, replacedBy: replacedBy.trim() || null },
      {
        onSuccess: () => {
          toast.success(discontinued ? `${pkg.name} is discontinued` : `${pkg.name} is continued`)
          onDone?.()
        },
      },
    )
  }

  return (
    <form onSubmit={submit} className="grid gap-4">
      {inDialog && (
        <DialogHeader>
          <DialogTitle>
            {pkg.isDiscontinued ? 'Continue' : 'Discontinue'} {pkg.name}
          </DialogTitle>
          <DialogDescription>
            A discontinued package stays available, but is hidden from the list and marked as such.
          </DialogDescription>
        </DialogHeader>
      )}
      <div className="flex items-center gap-2">
        <Checkbox
          id={`${id}-discontinued`}
          checked={discontinued}
          onCheckedChange={(value) => setDiscontinued(value === true)}
        />
        <Label htmlFor={`${id}-discontinued`} className="font-normal">
          Discontinued
        </Label>
      </div>
      <Field id={`${id}-replaced`} label="Replaced by (optional)" hint="A package on this server.">
        <Input
          id={`${id}-replaced`}
          value={replacedBy}
          disabled={!discontinued}
          onChange={(event) => setReplacedBy(event.target.value)}
          aria-describedby={`${id}-replaced-hint`}
          className="font-mono"
          spellCheck={false}
        />
      </Field>
      <FormError message={discontinue.error ? errorMessage(discontinue.error) : null} />
      <div className="flex justify-end gap-2">
        {inDialog && (
          <Button type="button" variant="outline" onClick={onDone}>
            Cancel
          </Button>
        )}
        <Button type="submit" disabled={discontinue.isPending}>
          {discontinue.isPending && <Loader2 aria-hidden className="animate-spin" />}
          Save
        </Button>
      </div>
    </form>
  )
}

export function UploadersDialog({ pkg, ...open }: Open & { pkg: Package }) {
  return (
    <Dialog {...open}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Uploaders of {pkg.name}</DialogTitle>
          <DialogDescription>
            Uploaders may publish new versions, retract them and manage this list.
          </DialogDescription>
        </DialogHeader>
        <UploadersEditor pkg={pkg} />
        <DialogFooter>
          <Button variant="outline" onClick={() => open.onOpenChange(false)}>
            Close
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

export function UploadersEditor({ pkg }: { pkg: Package }) {
  const id = useId()
  const add = useAddUploader()
  const remove = useRemoveUploader()
  const [email, setEmail] = useState('')
  const [removing, setRemoving] = useState<string | null>(null)

  return (
    <div className="grid gap-4">
      {pkg.uploaders.length === 0 ? (
        <p className="text-sm text-muted-foreground">
          No uploaders: only administrators can change this package.
        </p>
      ) : (
        <ul className="divide-y rounded-md border" aria-label="Uploaders">
          {pkg.uploaders.map((uploader) => (
            <li
              key={uploader}
              className="flex items-center justify-between gap-2 px-3 py-2 text-sm"
            >
              <span className="truncate">{uploader}</span>
              <Button
                variant="ghost"
                size="icon-sm"
                aria-label={`Remove ${uploader}`}
                disabled={remove.isPending}
                onClick={() => setRemoving(uploader)}
              >
                <Trash2 aria-hidden />
              </Button>
            </li>
          ))}
        </ul>
      )}
      <form
        className="flex items-end gap-2"
        onSubmit={(event) => {
          event.preventDefault()
          add.mutate(
            { name: pkg.name, email: email.trim() },
            {
              onSuccess: () => {
                toast.success(`Added ${email.trim()}`)
                setEmail('')
              },
            },
          )
        }}
      >
        <Field id={`${id}-email`} label="Add an uploader" className="flex-1">
          <Input
            id={`${id}-email`}
            type="email"
            required
            value={email}
            placeholder="jane.doe@company.example"
            onChange={(event) => setEmail(event.target.value)}
          />
        </Field>
        <Button type="submit" disabled={add.isPending}>
          <UserPlus aria-hidden />
          Add
        </Button>
      </form>
      <FormError message={add.error ? errorMessage(add.error) : null} />
      <ConfirmDialog
        open={removing !== null}
        onOpenChange={(open) => !open && setRemoving(null)}
        title={`Remove ${removing ?? ''}?`}
        description={`They can no longer publish ${pkg.name}. The last uploader cannot be removed.`}
        confirmLabel="Remove uploader"
        destructive
        onConfirm={async () => {
          if (!removing) return
          await remove.mutateAsync({ name: pkg.name, email: removing })
          toast.success(`Removed ${removing}`)
        }}
      />
    </div>
  )
}

export function TransferDialog({ pkg, ...open }: Open & { pkg: Package }) {
  const id = useId()
  const transfer = useTransferOwnership()
  const [email, setEmail] = useState('')
  return (
    <ConfirmDialog
      {...open}
      title={`Transfer ${pkg.name}`}
      description="The user becomes the only uploader. Every other uploader loses access."
      confirmLabel="Transfer ownership"
      destructive
      checkbox={`I understand that ${pkg.uploaders.length || 'the'} current uploader${pkg.uploaders.length === 1 ? '' : 's'} will be removed.`}
      onConfirm={async () => {
        await transfer.mutateAsync({ name: pkg.name, email: email.trim() })
        toast.success(`${pkg.name} now belongs to ${email.trim()}`)
        setEmail('')
      }}
    >
      <Field id={`${id}-owner`} label="New owner" hint="An existing user who may publish.">
        <Input
          id={`${id}-owner`}
          type="email"
          required
          value={email}
          onChange={(event) => setEmail(event.target.value)}
          aria-describedby={`${id}-owner-hint`}
        />
      </Field>
    </ConfirmDialog>
  )
}

export function DeleteVersionDialog({
  name,
  version,
  onDeleted,
  ...open
}: Open & { name: string; version: string; onDeleted?: () => void }) {
  const remove = useDeleteVersion()
  return (
    <ConfirmDialog
      {...open}
      title={`Delete ${name} ${version}?`}
      description="The version and its archive are deleted for good. Projects that locked it can no longer get it. Retracting is usually the better choice."
      confirmLabel="Delete version"
      destructive
      onConfirm={async () => {
        await remove.mutateAsync({ name, version })
        toast.success(`Deleted ${name} ${version}`)
        onDeleted?.()
      }}
    />
  )
}

export function DeletePackageDialog({
  name,
  onDeleted,
  ...open
}: Open & { name: string; onDeleted: () => void }) {
  const remove = useDeletePackage()
  return (
    <ConfirmDialog
      {...open}
      title={`Delete ${name}?`}
      description="Every version, archive and download count of the package is deleted for good. Projects depending on it break."
      confirmLabel="Delete package"
      destructive
      typeToConfirm={name}
      onConfirm={async () => {
        await remove.mutateAsync({ name })
        toast.success(`Deleted ${name}`)
        onDeleted()
      }}
    />
  )
}
