import { cn } from '@/lib/utils'

/** A placeholder block: a soft muted gradient that pulses (still with reduced motion). */
function Skeleton({ className, ...props }: React.ComponentProps<'div'>) {
  return (
    <div
      data-slot="skeleton"
      className={cn(
        'animate-pulse rounded-[5px] bg-linear-to-r from-muted via-[color-mix(in_oklab,var(--muted)_50%,var(--border))] to-muted',
        className,
      )}
      {...props}
    />
  )
}

export { Skeleton }
