import { useId, useState, type FormEvent, type ReactNode } from 'react'
import { Loader2, TriangleAlert, type LucideIcon } from 'lucide-react'
import { errorMessage } from '@/api/client'
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
import { FormError } from '@/components/form'

/**
 * Asks before an action. [typeToConfirm] makes the user type a value (the
 * package name), [checkbox] tick a box. Errors of [onConfirm] stay in the
 * dialog; it closes when [onConfirm] resolves.
 */
export function ConfirmDialog({
  open,
  onOpenChange,
  title,
  description,
  confirmLabel,
  destructive = false,
  confirmIcon,
  typeToConfirm,
  checkbox,
  onConfirm,
  children,
}: {
  open: boolean
  onOpenChange: (open: boolean) => void
  title: string
  description?: ReactNode
  confirmLabel: string
  destructive?: boolean
  /** An icon before [confirmLabel]. */
  confirmIcon?: LucideIcon
  typeToConfirm?: string
  checkbox?: string
  onConfirm: () => Promise<unknown>
  children?: ReactNode
}) {
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        {/* Remounted on every opening, so nothing typed lingers. */}
        {open && (
          <ConfirmForm
            title={title}
            description={description}
            confirmLabel={confirmLabel}
            destructive={destructive}
            confirmIcon={confirmIcon}
            typeToConfirm={typeToConfirm}
            checkbox={checkbox}
            onConfirm={onConfirm}
            onDone={() => onOpenChange(false)}
          >
            {children}
          </ConfirmForm>
        )}
      </DialogContent>
    </Dialog>
  )
}

function ConfirmForm({
  title,
  description,
  confirmLabel,
  destructive,
  confirmIcon: ConfirmIcon,
  typeToConfirm,
  checkbox,
  onConfirm,
  onDone,
  children,
}: {
  title: string
  description?: ReactNode
  confirmLabel: string
  destructive: boolean
  confirmIcon?: LucideIcon
  typeToConfirm?: string
  checkbox?: string
  onConfirm: () => Promise<unknown>
  onDone: () => void
  children?: ReactNode
}) {
  const id = useId()
  const [typed, setTyped] = useState('')
  const [ticked, setTicked] = useState(false)
  const [pending, setPending] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const ready =
    (typeToConfirm === undefined || typed === typeToConfirm) && (checkbox === undefined || ticked)

  const submit = async (event: FormEvent) => {
    event.preventDefault()
    if (!ready || pending) return
    setPending(true)
    setError(null)
    try {
      await onConfirm()
      onDone()
    } catch (failure) {
      setError(errorMessage(failure))
    } finally {
      setPending(false)
    }
  }

  return (
    <form onSubmit={submit} className="grid gap-4">
      <DialogHeader>
        <DialogTitle className="flex items-center gap-2">
          {destructive && (
            <TriangleAlert aria-hidden className="size-4.5 shrink-0 text-destructive" />
          )}
          {title}
        </DialogTitle>
        {description && (
          <DialogDescription asChild>
            <div>{description}</div>
          </DialogDescription>
        )}
      </DialogHeader>
      {children}
      {typeToConfirm !== undefined && (
        <div className="grid gap-1.5">
          <Label htmlFor={`${id}-confirm`} className="leading-5">
            <span>
              Type <code className="font-mono">{typeToConfirm}</code> to confirm
            </span>
          </Label>
          <Input
            id={`${id}-confirm`}
            value={typed}
            onChange={(event) => setTyped(event.target.value)}
            autoComplete="off"
            spellCheck={false}
            className="font-mono"
            autoFocus
          />
        </div>
      )}
      {checkbox !== undefined && (
        <div className="flex items-start gap-2 text-[0.8125rem]">
          <Checkbox
            id={`${id}-check`}
            checked={ticked}
            onCheckedChange={(value) => setTicked(value === true)}
          />
          <Label htmlFor={`${id}-check`} className="leading-4 font-normal">
            {checkbox}
          </Label>
        </div>
      )}
      <FormError id={`${id}-error`} message={error} />
      <DialogFooter>
        <Button type="button" variant="outline" onClick={onDone}>
          Cancel
        </Button>
        <Button
          type="submit"
          variant={destructive ? 'destructive' : 'default'}
          disabled={!ready || pending}
        >
          {pending ? (
            <Loader2 aria-hidden className="animate-spin" />
          ) : (
            ConfirmIcon && <ConfirmIcon aria-hidden />
          )}
          {confirmLabel}
        </Button>
      </DialogFooter>
    </form>
  )
}
