import * as React from 'react'
import { cn } from '@/lib/utils'
import { fieldClasses } from './input'

function Textarea({ className, ...props }: React.ComponentProps<'textarea'>) {
  return (
    <textarea
      data-slot="textarea"
      className={cn(
        fieldClasses,
        'flex field-sizing-content min-h-18 resize-y px-[11px] py-2',
        className,
      )}
      {...props}
    />
  )
}

export { Textarea }
