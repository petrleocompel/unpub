import * as React from 'react'
import { cva, type VariantProps } from 'class-variance-authority'
import { cn } from '@/lib/utils'

/*
 * Alerts and notices of docs/design (board 01): a tint of the state colour
 * on the card, the icon in that colour, the text in the foreground colour.
 * The text either has a title and a description, or is one run of text with
 * a bold lead (`<strong>Discontinued.</strong> Use ...`) in AlertDescription.
 */
const alertVariants = cva(
  'relative grid w-full grid-cols-[0_1fr] items-start gap-y-0.5 rounded-lg border px-3.5 py-3 text-[0.84375rem] leading-[1.3125rem] text-card-foreground has-[>svg]:grid-cols-[calc(var(--spacing)*4)_1fr] has-[>svg]:gap-x-3 [&_b]:font-semibold [&_strong]:font-semibold [&>svg]:size-4 [&>svg]:translate-y-0.5',
  {
    variants: {
      variant: {
        default: 'bg-card [&>svg]:text-muted-foreground',
        info: 'border-info/35 bg-[color-mix(in_oklab,var(--info)_7%,var(--card))] [&>svg]:text-info',
        warning:
          'border-warning/45 bg-[color-mix(in_oklab,var(--warning)_9%,var(--card))] [&>svg]:text-warning',
        destructive:
          'border-destructive/40 bg-[color-mix(in_oklab,var(--destructive)_7%,var(--card))] [&>svg]:text-destructive',
        success:
          'border-success/40 bg-[color-mix(in_oklab,var(--success)_8%,var(--card))] [&>svg]:text-success',
      },
    },
    defaultVariants: {
      variant: 'default',
    },
  },
)

function Alert({
  className,
  variant,
  ...props
}: React.ComponentProps<'div'> & VariantProps<typeof alertVariants>) {
  return (
    <div
      data-slot="alert"
      role="alert"
      className={cn(alertVariants({ variant }), className)}
      {...props}
    />
  )
}

function AlertTitle({ className, ...props }: React.ComponentProps<'div'>) {
  return (
    <div
      data-slot="alert-title"
      className={cn('col-start-2 min-h-4 font-semibold', className)}
      {...props}
    />
  )
}

function AlertDescription({ className, ...props }: React.ComponentProps<'div'>) {
  return (
    <div
      data-slot="alert-description"
      className={cn('col-start-2 grid justify-items-start gap-1', className)}
      {...props}
    />
  )
}

export { Alert, AlertTitle, AlertDescription }
