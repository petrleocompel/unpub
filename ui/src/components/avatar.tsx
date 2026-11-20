import { cn } from '@/lib/utils'

/** "jane.doe@company.example" → "JD"; one letter more when there is one word. */
export function initialsOf(email: string) {
  const local = email.split('@')[0] ?? email
  const words = local.split(/[._\-+\s]+/).filter(Boolean)
  const letters =
    words.length >= 2 ? `${words[0]![0]}${words[1]![0]}` : (words[0] ?? local).slice(0, 2)
  return letters.toUpperCase()
}

/**
 * The initials of a user in a round chip, as docs/design draws uploaders and
 * the user menu. Decorative: the email is always next to it.
 */
export function Initials({
  email,
  size = 'sm',
  className,
}: {
  email: string
  size?: 'sm' | 'md' | 'lg'
  className?: string
}) {
  return (
    <span
      aria-hidden
      className={cn(
        'inline-grid shrink-0 place-items-center rounded-full bg-secondary font-semibold text-secondary-foreground',
        size === 'sm' && 'size-5.5 text-[0.625rem]',
        size === 'md' && 'size-7 text-xs',
        size === 'lg' && 'size-11 text-base',
        className,
      )}
    >
      {initialsOf(email)}
    </span>
  )
}
