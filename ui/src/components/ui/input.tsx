import * as React from 'react'
import { cn } from '@/lib/utils'

/** The field classes shared by inputs, textareas and selects (board 01). */
export const fieldClasses = cn(
  'w-full min-w-0 rounded-md border border-input bg-background text-sm text-foreground shadow-xs transition-[color,border-color,box-shadow] outline-none',
  'selection:bg-primary selection:text-primary-foreground placeholder:text-muted-foreground',
  'disabled:pointer-events-none disabled:cursor-not-allowed disabled:opacity-50',
  // Inputs have a 3 px soft halo on focus instead of the outline.
  'focus-visible:border-ring focus-visible:ring-[3px] focus-visible:ring-ring/22',
  'aria-invalid:border-destructive aria-invalid:ring-[3px] aria-invalid:ring-destructive/18',
)

function Input({ className, type, ...props }: React.ComponentProps<'input'>) {
  return (
    <input
      type={type}
      data-slot="input"
      className={cn(
        fieldClasses,
        'h-9 px-[11px] py-1',
        'file:inline-flex file:h-7 file:border-0 file:bg-transparent file:text-sm file:font-medium file:text-foreground',
        className,
      )}
      {...props}
    />
  )
}

export { Input }
