import type { ReactNode } from 'react'
import { CircleAlert } from 'lucide-react'
import { Label } from '@/components/ui/label'
import { cn } from '@/lib/utils'

/**
 * The error of a form, announced when it appears. Fields it is about point to
 * its [id] with [invalidField].
 */
export function FormError({ message, id }: { message: string | null | undefined; id: string }) {
  if (!message) return null
  return (
    <p
      id={id}
      role="alert"
      className="flex items-start gap-3 rounded-lg border border-destructive/40 bg-[color-mix(in_oklab,var(--destructive)_7%,var(--card))] px-3.5 py-3 text-[0.84375rem] leading-[1.3125rem]"
    >
      <CircleAlert aria-hidden className="mt-0.5 size-4 shrink-0 text-destructive" />
      <span>{message}</span>
    </p>
  )
}

/**
 * The attributes of a field the error [errorId] is about while [invalid],
 * keeping its hint ([describedBy]) described as well.
 */
export function invalidField(errorId: string, invalid: boolean, describedBy?: string) {
  const ids = [describedBy, invalid ? errorId : undefined].filter(Boolean).join(' ')
  return {
    'aria-invalid': invalid || undefined,
    'aria-errormessage': invalid ? errorId : undefined,
    'aria-describedby': ids || undefined,
  }
}

/** A label, a control and an optional hint, connected for screen readers. */
export function Field({
  id,
  label,
  hint,
  children,
  className,
}: {
  id: string
  label: ReactNode
  hint?: ReactNode
  children: ReactNode
  className?: string
}) {
  return (
    <div className={cn('grid content-start gap-1.5', className)}>
      <Label htmlFor={id}>{label}</Label>
      {children}
      {hint && (
        <p id={`${id}-hint`} className="text-xs leading-4 text-muted-foreground">
          {hint}
        </p>
      )}
    </div>
  )
}
