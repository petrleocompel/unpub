import { useId } from 'react'
import { pillItem, pillTrack } from '@/components/ui/segmented'
import { cn } from '@/lib/utils'

/**
 * A few options always in view, one pressed: a group of toggle buttons with
 * a visible label. The chrome is the shared pill of `ui/segmented`, so a
 * restyle there reaches the dashboard too.
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
      <div role="group" aria-labelledby={id} className={cn(pillTrack, 'w-fit')}>
        {options.map((option) => {
          const pressed = option.value === value
          return (
            <button
              key={option.value}
              type="button"
              aria-pressed={pressed}
              data-state={pressed ? 'active' : 'inactive'}
              onClick={() => onChange(option.value)}
              className={pillItem}
            >
              {option.label}
            </button>
          )
        })}
      </div>
    </div>
  )
}
