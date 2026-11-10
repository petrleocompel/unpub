import { ChevronLeft, ChevronRight } from 'lucide-react'
import { Link, useLocation, useSearchParams } from 'react-router'
import { buttonVariants } from '@/components/ui/button'
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
 * parameter, one-based; [sizes] adds a page size selector on `size`.
 */
export function Pager({
  page,
  size,
  total,
  sizes,
  label = 'Pages',
}: {
  page: number
  size: number
  total: number
  sizes?: number[]
  label?: string
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
  const link = (enabled: boolean) =>
    cn(
      buttonVariants({ variant: 'ghost', size: 'sm' }),
      !enabled && 'pointer-events-none opacity-50',
    )

  return (
    <div className="flex flex-wrap items-center justify-between gap-3 text-sm">
      <p className="text-muted-foreground" aria-live="polite">
        {total === 0
          ? 'No results'
          : `${formatNumber(first)}–${formatNumber(last)} of ${formatNumber(total)}`}
      </p>
      <div className="flex flex-wrap items-center gap-3">
        {sizes && (
          <label className="flex items-center gap-2 text-muted-foreground">
            Per page
            <NativeSelect
              value={String(size)}
              className="h-8 w-20"
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
        {pages > 1 && (
          <nav aria-label={label}>
            <ul className="flex items-center gap-1">
              <li>
                <Link
                  to={href(page - 1)}
                  className={link(page > 1)}
                  aria-disabled={page <= 1}
                  tabIndex={page <= 1 ? -1 : undefined}
                  rel="prev"
                >
                  <ChevronLeft aria-hidden />
                  <span>Previous</span>
                </Link>
              </li>
              {pageWindow(page, pages).map((item, index) =>
                item === 'gap' ? (
                  <li key={`gap-${index}`} aria-hidden className="px-1 text-muted-foreground">
                    …
                  </li>
                ) : (
                  <li key={item}>
                    <Link
                      to={href(item)}
                      aria-current={item === page ? 'page' : undefined}
                      aria-label={`Page ${item}`}
                      className={cn(
                        buttonVariants({
                          variant: item === page ? 'outline' : 'ghost',
                          size: 'sm',
                        }),
                        'min-w-8',
                      )}
                    >
                      {item}
                    </Link>
                  </li>
                ),
              )}
              <li>
                <Link
                  to={href(page + 1)}
                  className={link(page < pages)}
                  aria-disabled={page >= pages}
                  tabIndex={page >= pages ? -1 : undefined}
                  rel="next"
                >
                  <span>Next</span>
                  <ChevronRight aria-hidden />
                </Link>
              </li>
            </ul>
          </nav>
        )}
      </div>
    </div>
  )
}

/** A positive integer query parameter, or [fallback]. */
export function intParam(params: URLSearchParams, name: string, fallback: number, max?: number) {
  const value = Number(params.get(name))
  if (!Number.isInteger(value) || value < 1) return fallback
  return max ? Math.min(value, max) : value
}
