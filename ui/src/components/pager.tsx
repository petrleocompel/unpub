import { ChevronLeft, ChevronRight } from 'lucide-react'
import { Link, useLocation, useSearchParams } from 'react-router'
import { NativeSelect } from '@/components/native-select'
import { formatNumber } from '@/lib/format'
import { cn } from '@/lib/utils'

/** The page numbers to show: the first, the last and two around [page]. */
export function pageWindow(page: number, pages: number): (number | 'gap')[] {
  const shown = new Set([1, pages, page - 1, page, page + 1].filter((p) => p >= 1 && p <= pages))
  const sorted = [...shown].sort((a, b) => a - b)
  const result: (number | 'gap')[] = []
  for (const [index, value] of sorted.entries()) {
    const previous = sorted[index - 1]
    if (previous !== undefined && value - previous > 1) result.push('gap')
    result.push(value)
  }
  return result
}

/**
 * Page links that keep the other query parameters. The page is the `page`
 * parameter, one-based; [sizes] adds a page size selector on `size`, named
 * [sizeLabel]. Laid out as board 03: the range on the left, the pages in the
 * middle, the size on the right; centred on phones.
 */
export function Pager({
  page,
  size,
  total,
  sizes,
  label = 'Pages',
  sizeLabel = 'Per page',
  className,
}: {
  page: number
  size: number
  total: number
  sizes?: number[]
  label?: string
  sizeLabel?: string
  className?: string
}) {
  const [params, setParams] = useSearchParams()
  const location = useLocation()
  const pages = Math.max(1, Math.ceil(total / size))
  const href = (target: number) => {
    const next = new URLSearchParams(params)
    if (target <= 1) next.delete('page')
    else next.set('page', String(target))
    const query = next.toString()
    return `${location.pathname}${query ? `?${query}` : ''}`
  }
  const first = total === 0 ? 0 : (page - 1) * size + 1
  const last = Math.min(total, page * size)
  const item =
    'inline-grid h-8 min-w-8 place-items-center rounded-md px-1.5 text-[0.8125rem] font-medium text-foreground tabular-nums'
  const step = (enabled: boolean) =>
    cn(
      item,
      'hover:bg-accent [&_svg]:size-4',
      !enabled && 'pointer-events-none text-muted-foreground opacity-60',
    )

  return (
    <div
      className={cn(
        'flex flex-wrap items-center justify-center gap-3 text-[0.8125rem] text-muted-foreground sm:justify-between',
        className,
      )}
    >
      <p aria-live="polite" className="tabular-nums">
        {total === 0
          ? 'No results'
          : `${formatNumber(first)}–${formatNumber(last)} of ${formatNumber(total)}`}
      </p>
      {pages > 1 && (
        <nav aria-label={label}>
          <ul className="flex items-center gap-0.5">
            <li>
              <Link
                to={href(page - 1)}
                className={step(page > 1)}
                aria-disabled={page <= 1}
                aria-label="Previous page"
                tabIndex={page <= 1 ? -1 : undefined}
                rel="prev"
              >
                <ChevronLeft aria-hidden />
              </Link>
            </li>
            {pageWindow(page, pages).map((value, index) =>
              value === 'gap' ? (
                <li key={`gap-${index}`} aria-hidden className={item}>
                  …
                </li>
              ) : (
                <li key={value}>
                  <Link
                    to={href(value)}
                    aria-current={value === page ? 'page' : undefined}
                    aria-label={`Page ${value}`}
                    className={cn(
                      item,
                      value === page ? 'bg-primary text-primary-foreground' : 'hover:bg-accent',
                    )}
                  >
                    {value}
                  </Link>
                </li>
              ),
            )}
            <li>
              <Link
                to={href(page + 1)}
                className={step(page < pages)}
                aria-disabled={page >= pages}
                aria-label="Next page"
                tabIndex={page >= pages ? -1 : undefined}
                rel="next"
              >
                <ChevronRight aria-hidden />
              </Link>
            </li>
          </ul>
        </nav>
      )}
      {sizes && (
        <label className="flex basis-full items-center justify-center gap-2 sm:basis-auto">
          {sizeLabel}
          <NativeSelect
            small
            value={String(size)}
            className="w-18"
            onChange={(event) => {
              const next = new URLSearchParams(params)
              next.set('size', event.target.value)
              next.delete('page')
              setParams(next)
            }}
          >
            {sizes.map((value) => (
              <option key={value} value={value}>
                {value}
              </option>
            ))}
          </NativeSelect>
        </label>
      )}
    </div>
  )
}

/** A positive integer query parameter, or [fallback]. */
export function intParam(params: URLSearchParams, name: string, fallback: number, max?: number) {
  const value = Number(params.get(name))
  if (!Number.isInteger(value) || value < 1) return fallback
  return max ? Math.min(value, max) : value
}
