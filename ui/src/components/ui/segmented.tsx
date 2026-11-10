import * as React from 'react'
import { cn } from '@/lib/utils'

/**
 * A segmented control (board 01): a few options, always visible, one
 * click. Each option is a real button with `aria-pressed`, so it is in the
 * tab order and announced as a toggle; the group is named by [label].
 */
function SegmentedControl<T extends string>({
  label,
  value,
  options,
  onValueChange,
  className,
}: {
  label: string
  value: T
  options: { value: T; label: React.ReactNode }[]
  onValueChange: (value: T) => void
  className?: string
}) {
  return (
    <div
      role="group"
      aria-label={label}
      data-slot="segmented-control"
      className={cn('inline-flex gap-0.5 rounded-lg border bg-muted p-[3px]', className)}
    >
      {options.map((option) => {
        const pressed = option.value === value
        return (
          <button
            key={option.value}
            type="button"
            aria-pressed={pressed}
            onClick={() => {
              if (!pressed) onValueChange(option.value)
            }}
            className={cn(
              'inline-flex h-6.5 items-center gap-1.5 rounded-[5px] px-3 text-[0.8125rem] font-medium text-muted-foreground transition-colors hover:text-foreground [&_svg]:size-3.5 [&_svg]:shrink-0',
              pressed && 'bg-background text-foreground shadow-xs ring-1 ring-border',
            )}
          >
            {option.label}
          </button>
        )
      })}
    </div>
  )
}

export { SegmentedControl }
