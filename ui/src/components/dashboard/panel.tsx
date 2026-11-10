import type { ComponentProps, ReactNode } from 'react'
import { cn } from '@/lib/utils'

/**
 * A card of the dashboard: a bordered section with a header, a body and a
 * footer on the surface colour. Denser than the public cards.
 */
export function Panel({ className, ...props }: ComponentProps<'section'>) {
  return (
    <section
      className={cn('min-w-0 rounded-lg border bg-card text-card-foreground', className)}
      {...props}
    />
  )
}

export function PanelHeader({
  title,
  description,
  titleId,
  titleClassName,
  children,
  className,
}: {
  title: ReactNode
  description?: ReactNode
  titleId?: string
  titleClassName?: string
  children?: ReactNode
  className?: string
}) {
  return (
    <div
      className={cn(
        'flex flex-wrap items-center justify-between gap-3 border-b px-3.5 py-3.5 sm:px-4.5',
        className,
      )}
    >
      <div className="grid min-w-0">
        <h2
          id={titleId}
          className={cn('text-[0.9375rem] leading-[1.375rem] font-semibold', titleClassName)}
        >
          {title}
        </h2>
        {description && <p className="text-xs text-muted-foreground">{description}</p>}
      </div>
      {children}
    </div>
  )
}

export function PanelBody({ className, ...props }: ComponentProps<'div'>) {
  return <div className={cn('px-3.5 py-4.5 sm:px-4.5', className)} {...props} />
}

export function PanelFooter({ className, ...props }: ComponentProps<'div'>) {
  return (
    <div
      className={cn(
        'flex flex-wrap items-center justify-end gap-2 rounded-b-lg border-t bg-surface px-3.5 py-3 sm:px-4.5',
        className,
      )}
      {...props}
    />
  )
}

/** A tinted status badge: a dot or an icon and a word, never the colour alone. */
export function ToneBadge({
  tone,
  dot = false,
  children,
  className,
}: {
  tone: 'success' | 'warning' | 'danger' | 'neutral'
  dot?: boolean
  children: ReactNode
  className?: string
}) {
  return (
    <span
      className={cn(
        'inline-flex h-5.5 shrink-0 items-center gap-1 rounded-full border px-2 text-xs leading-none font-medium whitespace-nowrap text-foreground [&>svg]:size-3',
        tone === 'success' && 'border-success/35 bg-success/12 [&>svg]:text-success',
        tone === 'warning' && 'border-warning/40 bg-warning/13 [&>svg]:text-warning',
        tone === 'danger' && 'border-destructive/35 bg-destructive/10 [&>svg]:text-destructive',
        tone === 'neutral' && 'bg-background',
        className,
      )}
    >
      {dot && (
        <span
          aria-hidden
          className={cn(
            'size-1.75 rounded-full',
            tone === 'success' && 'bg-success',
            tone === 'warning' && 'bg-warning',
            tone === 'danger' && 'bg-destructive',
            tone === 'neutral' && 'bg-muted-foreground',
          )}
        />
      )}
      {children}
    </span>
  )
}

/** An event name or another identifier, as a small monospace chip. */
export function Chip({ children, className }: { children: ReactNode; className?: string }) {
  return (
    <span
      className={cn(
        'inline-flex h-5.5 items-center rounded-[5px] border bg-muted px-1.75 font-mono text-[0.71875rem] whitespace-nowrap text-foreground',
        className,
      )}
    >
      {children}
    </span>
  )
}
