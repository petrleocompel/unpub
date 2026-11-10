import * as React from 'react'
import { cva, type VariantProps } from 'class-variance-authority'
import { cn } from '@/lib/utils'
import { Slot } from 'radix-ui'

/*
 * Buttons of docs/design (board 01): 36 px default, 30 px small, 26 px extra
 * small, 6 px radius. The focus ring is the global one: 2 px --ring, 2 px
 * offset (src/index.css).
 */
const buttonVariants = cva(
  "inline-flex shrink-0 items-center justify-center gap-1.5 rounded-md border border-transparent text-sm font-medium whitespace-nowrap transition-[color,background-color,border-color,box-shadow] disabled:pointer-events-none disabled:opacity-50 aria-disabled:pointer-events-none aria-disabled:opacity-50 [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4",
  {
    variants: {
      variant: {
        default: 'bg-primary text-primary-foreground shadow-xs hover:bg-primary/90',
        destructive: 'bg-destructive text-destructive-foreground shadow-xs hover:bg-destructive/90',
        'destructive-outline':
          'border-destructive/45 bg-background text-destructive hover:bg-destructive/10',
        outline:
          'border-input bg-background shadow-xs hover:bg-accent hover:text-accent-foreground',
        secondary: 'bg-secondary text-secondary-foreground hover:bg-secondary/80',
        ghost: 'hover:bg-accent hover:text-accent-foreground',
        link: 'h-auto! border-0 px-0! font-medium text-primary underline-offset-4 hover:underline',
      },
      size: {
        default: 'h-9 px-3.5',
        xs: "h-6.5 gap-1 rounded-[5px] px-2 text-xs [&_svg:not([class*='size-'])]:size-3.5",
        sm: "h-7.5 gap-[5px] px-2.5 text-[0.8125rem] [&_svg:not([class*='size-'])]:size-3.5",
        lg: 'h-10 px-5',
        icon: 'size-9',
        'icon-xs': "size-6.5 rounded-[5px] [&_svg:not([class*='size-'])]:size-3.5",
        'icon-sm': 'size-7.5',
        'icon-lg': 'size-10',
      },
    },
    defaultVariants: {
      variant: 'default',
      size: 'default',
    },
  },
)

function Button({
  className,
  variant = 'default',
  size = 'default',
  asChild = false,
  ...props
}: React.ComponentProps<'button'> &
  VariantProps<typeof buttonVariants> & {
    asChild?: boolean
  }) {
  const Comp = asChild ? Slot.Root : 'button'

  return (
    <Comp
      data-slot="button"
      data-variant={variant}
      data-size={size}
      className={cn(buttonVariants({ variant, size, className }))}
      {...props}
    />
  )
}

export { Button, buttonVariants }
