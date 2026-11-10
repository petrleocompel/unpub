import * as React from 'react'
import { cva, type VariantProps } from 'class-variance-authority'
import { cn } from '@/lib/utils'
import { Slot } from 'radix-ui'

/*
 * Badges of docs/design (board 01): 22 px pills, 12 px medium text, a 12 px
 * icon. Status tones are tints of a state colour with the icon in that
 * colour, so the word, not the colour, carries the meaning.
 */
const badgeVariants = cva(
  'inline-flex h-5.5 w-fit shrink-0 items-center justify-center gap-1 overflow-hidden rounded-full border border-transparent px-2 text-xs leading-none font-medium whitespace-nowrap transition-[color,background-color] [&>svg]:pointer-events-none [&>svg]:size-3',
  {
    variants: {
      variant: {
        default: 'bg-primary text-primary-foreground [a&]:hover:bg-primary/90',
        secondary: 'bg-secondary text-secondary-foreground [a&]:hover:bg-secondary/90',
        destructive: 'bg-destructive text-destructive-foreground [a&]:hover:bg-destructive/90',
        outline: 'border-border bg-background text-foreground [a&]:hover:bg-accent',
        primary: 'border-primary/30 bg-primary/12 text-foreground [&>svg]:text-primary',
        success: 'border-success/35 bg-success/12 text-foreground [&>svg]:text-success',
        warning: 'border-warning/40 bg-warning/13 text-foreground [&>svg]:text-warning',
        danger: 'border-destructive/35 bg-destructive/10 text-foreground [&>svg]:text-destructive',
        ghost: '[a&]:hover:bg-accent [a&]:hover:text-accent-foreground',
        link: 'text-primary underline-offset-4 [a&]:hover:underline',
      },
    },
    defaultVariants: {
      variant: 'default',
    },
  },
)

function Badge({
  className,
  variant = 'default',
  asChild = false,
  ...props
}: React.ComponentProps<'span'> & VariantProps<typeof badgeVariants> & { asChild?: boolean }) {
  const Comp = asChild ? Slot.Root : 'span'

  return (
    <Comp
      data-slot="badge"
      data-variant={variant}
      className={cn(badgeVariants({ variant }), className)}
      {...props}
    />
  )
}

export { Badge, badgeVariants }
