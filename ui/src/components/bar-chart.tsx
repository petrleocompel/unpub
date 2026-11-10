import { formatDate, formatNumber } from '@/lib/format'
import { cn } from '@/lib/utils'

/** A round axis maximum at or above [peak], split in three steps. */
export function axisMax(peak: number) {
  if (peak <= 0) return 3
  const rough = peak / 3
  const magnitude = 10 ** Math.floor(Math.log10(rough))
  const step = [1, 2, 2.5, 5, 10].map((m) => m * magnitude).find((s) => s >= rough) ?? rough
  return Math.max(3, Math.ceil(step) * 3)
}

/**
 * Downloads per day as bars (board 07), drawn as SVG with attributes and
 * classes only: the Content-Security-Policy refuses `style` attributes. The
 * axis labels are HTML next to the drawing so they keep their size. The
 * chart is one image for screen readers, with [label] as its summary; the
 * page offers the same numbers as a table.
 */
export function BarChart({
  data,
  label,
  className,
}: {
  data: { day: string; count: number }[]
  label: string
  className?: string
}) {
  const width = 900
  const height = 200
  const peak = Math.max(0, ...data.map((d) => d.count))
  const max = axisMax(peak)
  const slot = width / Math.max(1, data.length)
  const bar = Math.max(2, slot * 0.74)
  const busiest = peak > 0 ? data.findIndex((d) => d.count === peak) : -1
  const first = data[0]
  const middle = data[Math.floor(data.length / 2)]
  const last = data[data.length - 1]
  const ticks = [max, (max * 2) / 3, max / 3, 0]

  return (
    <figure className={cn('grid gap-2.5', className)}>
      <div className="grid grid-cols-[auto_minmax(0,1fr)] gap-x-2 gap-y-1.5">
        <div
          aria-hidden
          className="-my-1.5 flex h-50 flex-col justify-between text-right text-[0.6875rem] leading-3 text-muted-foreground tabular-nums"
        >
          {ticks.map((tick) => (
            <span key={tick}>{formatNumber(Math.round(tick))}</span>
          ))}
        </div>
        <svg
          viewBox={`0 0 ${width} ${height}`}
          className="h-50 w-full"
          role="img"
          aria-label={label}
          preserveAspectRatio="none"
        >
          {[0, 1, 2, 3].map((index) => {
            const y = Math.min(height - 0.5, Math.max(0.5, (index * height) / 3))
            return (
              <line
                key={index}
                x1={0}
                x2={width}
                y1={y}
                y2={y}
                className="stroke-chart-grid"
                vectorEffect="non-scaling-stroke"
              />
            )
          })}
          {data.map((d, index) => {
            const h = (d.count / max) * height
            return (
              <rect
                key={d.day}
                x={index * slot + (slot - bar) / 2}
                y={height - Math.max(h, d.count > 0 ? 2 : 0)}
                width={bar}
                height={Math.max(h, d.count > 0 ? 2 : 0)}
                rx={2}
                className={cn(
                  index === busiest
                    ? 'fill-[color-mix(in_oklab,var(--chart-bar)_70%,var(--foreground))]'
                    : 'fill-chart-bar',
                )}
              >
                <title>{`${formatDate(d.day)} · ${formatNumber(d.count)} downloads`}</title>
              </rect>
            )
          })}
        </svg>
        <span />
        <div
          aria-hidden
          className="flex justify-between text-[0.6875rem] text-muted-foreground tabular-nums"
        >
          <span>{first ? formatDate(first.day) : ''}</span>
          <span>{middle && data.length > 2 ? formatDate(middle.day) : ''}</span>
          <span>{last ? formatDate(last.day) : ''}</span>
        </div>
      </div>
      <figcaption className="flex flex-wrap items-center gap-2 text-xs text-muted-foreground">
        {busiest >= 0 ? (
          <span className="rounded-[5px] bg-foreground px-2 py-[5px] text-background shadow-md">
            Busiest {formatDate(data[busiest]!.day)} · {formatNumber(peak)} downloads
          </span>
        ) : (
          <span>No downloads in this period.</span>
        )}
        <span>Hover a bar for its day; the Table view lists every day.</span>
      </figcaption>
    </figure>
  )
}
