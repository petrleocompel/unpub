import * as React from 'react'
import { cva, type VariantProps } from 'class-variance-authority'
import { cn } from '@/lib/utils'
import { Tabs as TabsPrimitive } from 'radix-ui'
import { pillItem, pillTrack } from './segmented'

function Tabs({
  className,
  orientation = 'horizontal',
  ...props
}: React.ComponentProps<typeof TabsPrimitive.Root>) {
  return (
    <TabsPrimitive.Root
      data-slot="tabs"
      data-orientation={orientation}
      orientation={orientation}
      className={cn('group/tabs flex gap-2 data-[orientation=horizontal]:flex-col', className)}
      {...props}
    />
  )
}

/*
 * The default variant is the segmented pill of SegmentedControl (the same
 * classes, see segmented.tsx); the line variant is the tab row of
 * docs/design (board 01): 42 px tabs with a 2 px primary underline,
 * scrolling sideways when they do not fit.
 */
const tabsListVariants = cva(
  'group/tabs-list w-fit items-center text-muted-foreground group-data-[orientation=vertical]/tabs:h-fit group-data-[orientation=vertical]/tabs:flex-col',
  {
    variants: {
      variant: {
        default: cn(pillTrack, 'justify-center'),
        line: 'inline-flex max-w-full justify-start gap-1 overflow-x-auto overflow-y-hidden border-b group-data-[orientation=horizontal]/tabs:h-auto',
      },
    },
    defaultVariants: {
      variant: 'default',
    },
  },
)

type TabsVariant = NonNullable<VariantProps<typeof tabsListVariants>['variant']>
const TabsVariantContext = React.createContext<TabsVariant>('default')

function TabsList({
  className,
  variant = 'default',
  ...props
}: React.ComponentProps<typeof TabsPrimitive.List> & VariantProps<typeof tabsListVariants>) {
  const resolved = variant ?? 'default'
  return (
    <TabsVariantContext.Provider value={resolved}>
      <TabsPrimitive.List
        data-slot="tabs-list"
        data-variant={resolved}
        className={cn(tabsListVariants({ variant: resolved }), className)}
        {...props}
      />
    </TabsVariantContext.Provider>
  )
}

const tabsTriggerVariants: Record<TabsVariant, string> = {
  default: cn(pillItem, 'flex-1'),
  // The list scrolls, which clips anything outside it: the focus ring of a
  // line tab is drawn inside the tab.
  line: "relative -mb-px inline-flex h-10.5 items-center justify-center gap-1.5 border-b-2 border-transparent px-3 text-sm font-medium whitespace-nowrap text-muted-foreground transition-colors hover:text-foreground focus-visible:-outline-offset-2 data-[state=active]:border-primary data-[state=active]:text-foreground [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4",
}

function TabsTrigger({ className, ...props }: React.ComponentProps<typeof TabsPrimitive.Trigger>) {
  const variant = React.useContext(TabsVariantContext)
  return (
    <TabsPrimitive.Trigger
      data-slot="tabs-trigger"
      className={cn(
        tabsTriggerVariants[variant],
        'disabled:pointer-events-none disabled:opacity-50',
        'group-data-[orientation=vertical]/tabs:w-full group-data-[orientation=vertical]/tabs:justify-start',
        className,
      )}
      {...props}
    />
  )
}

/** The count next to a tab label, as "Versions 14". */
function TabsCount({ className, ...props }: React.ComponentProps<'span'>) {
  return (
    <span
      data-slot="tabs-count"
      className={cn(
        'rounded-full bg-secondary px-1.5 py-px text-[0.6875rem] font-semibold text-muted-foreground tabular-nums',
        className,
      )}
      {...props}
    />
  )
}

function TabsContent({ className, ...props }: React.ComponentProps<typeof TabsPrimitive.Content>) {
  return (
    <TabsPrimitive.Content
      data-slot="tabs-content"
      className={cn('flex-1 outline-none', className)}
      {...props}
    />
  )
}

export { Tabs, TabsList, TabsTrigger, TabsCount, TabsContent, tabsListVariants }
