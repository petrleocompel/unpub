import { useId } from 'react'
import { cn } from '@/lib/utils'

/**
 * A few options always in view, one pressed: a group of toggle buttons with
 * a visible label.
 */
export function Segmented<T extends string>({
  label,
  value,
  options,
  onChange,
  className,
}: {
  label: string
  value: T
  options: { value: T; label: string }[]
  onChange: (value: T) => void
  className?: string
}) {
  const id = useId()
  return (
    <div className={cn('grid gap-2', className)}>
      <span id={id} className="text-sm leading-none font-medium">
        {label}
      </span>
      <div
        role="group"
        aria-labelledby={id}
        className="inline-flex h-9 w-fit items-center gap-0.5 rounded-lg border bg-muted p-0.75"
      >
        {options.map((option) => (
          <button
            key={option.value}
            type="button"
            aria-pressed={option.value === value}
            onClick={() => onChange(option.value)}
            className={cn(
              'h-6.5 rounded-[5px] px-3 text-[0.8125rem] font-medium whitespace-nowrap text-muted-foreground outline-none hover:text-foreground focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 focus-visible:ring-offset-muted',
              option.value === value &&
                'bg-background text-foreground shadow-xs ring-1 ring-border',
            )}
          >
            {option.label}
          </button>
        ))}
      </div>
    </div>
  )
}
