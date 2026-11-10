import type { ComponentProps } from 'react'
import { Table } from '@/components/ui/table'
import { cn } from '@/lib/utils'

/**
 * A table of the dashboard: the compact table with its first column kept in
 * view while the rest scrolls sideways. [boxed] draws its own border, for a
 * table that is not inside a panel. Mark an expanded row with
 * `data-expanded`, an inactive one with `data-muted`.
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
        '[&_thead_th:first-child]:bg-surface',
        '[&_tr[data-expanded]>td]:bg-surface [&_tr[data-muted]>td]:text-muted-foreground',
        className,
      )}
      {...props}
    />
  )
}
