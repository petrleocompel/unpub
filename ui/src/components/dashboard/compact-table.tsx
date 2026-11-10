import type { ComponentProps } from 'react'
import { Table } from '@/components/ui/table'
import { cn } from '@/lib/utils'

/**
 * The dense table of the dashboard: 13 px text, 40 px rows, the header on the
 * surface colour, no stripes. The first column stays in view while the rest
 * scrolls sideways. [boxed] draws its own border, for a table that is not
 * inside a panel. Mark a sorted column with `aria-sort` on its header and an
 * expanded row with `data-expanded`, an inactive one with `data-muted`.
 */
export function CompactTable({
  boxed = true,
  className,
  containerClassName,
  ...props
}: ComponentProps<typeof Table> & { boxed?: boolean }) {
  return (
    <Table
      stickyFirstColumn
      containerClassName={cn(
        '[--sticky-bg:var(--color-card)]',
        boxed && 'rounded-lg border bg-card',
        containerClassName,
      )}
      className={cn(
        'text-[0.8125rem] leading-5',
        '[&_th]:h-9 [&_th]:bg-surface [&_th]:px-3 [&_th]:text-xs [&_th]:font-semibold [&_th]:text-muted-foreground [&_th[aria-sort]]:text-foreground',
        '[&_td]:h-10 [&_td]:px-3 [&_td]:py-1.5',
        '[&_tr[data-expanded]>td]:bg-surface [&_tr[data-muted]>td]:text-muted-foreground',
        className,
      )}
      {...props}
    />
  )
}
