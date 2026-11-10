import * as React from 'react'
import { cn } from '@/lib/utils'

/*
 * The pill chrome of board 01, shared by SegmentedControl and the default
 * variant of TabsList: a muted track and a raised chip for the selected
 * option. The chip is keyed on data-state="active", which Radix sets on a
 * tab and SegmentedControl sets on its pressed button. Restyle both here.
 */
const pillTrack = 'inline-flex gap-0.5 rounded-lg border bg-muted p-[3px]'
const pillItem = cn(
  'inline-flex h-6.5 items-center justify-center gap-1.5 rounded-[5px] px-3 text-[0.8125rem] font-medium whitespace-nowrap text-muted-foreground transition-colors hover:text-foreground [&_svg]:pointer-events-none [&_svg]:size-3.5 [&_svg]:shrink-0',
  'data-[state=active]:bg-background data-[state=active]:text-foreground data-[state=active]:shadow-xs data-[state=active]:ring-1 data-[state=active]:ring-border',
)

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
      className={cn(pillTrack, className)}
    >
      {options.map((option) => {
        const pressed = option.value === value
        return (
          <button
            key={option.value}
            type="button"
            aria-pressed={pressed}
            data-state={pressed ? 'active' : 'inactive'}
            onClick={() => {
              if (!pressed) onValueChange(option.value)
            }}
            className={pillItem}
          >
            {option.label}
          </button>
        )
      })}
    </div>
  )
}

export { SegmentedControl, pillItem, pillTrack }
