import type { ComponentProps } from 'react'
import { ChevronDown } from 'lucide-react'
import { cn } from '@/lib/utils'
import { fieldClasses } from '@/components/ui/input'

/**
 * A native <select> styled like the inputs. Radix Select is not used: it
 * renders an inline <style> element that the Content-Security-Policy refuses.
 * [small] is the 32 px toolbar size; the width comes from [className].
 */
export function NativeSelect({
  className,
  children,
  small = false,
  ...props
}: ComponentProps<'select'> & { small?: boolean }) {
  return (
    <span className={cn('relative inline-flex', small ? 'h-8' : 'h-9', className)}>
      <select
        className={cn(
          fieldClasses,
          'h-full appearance-none pr-7.5 pl-[11px]',
          small && 'text-[0.8125rem]',
        )}
        {...props}
      >
        {children}
      </select>
      <ChevronDown
        aria-hidden
        className="pointer-events-none absolute top-1/2 right-2.5 size-3.5 -translate-y-1/2 text-muted-foreground"
      />
    </span>
  )
}
