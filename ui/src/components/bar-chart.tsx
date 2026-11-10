import { formatDate, formatNumber } from '@/lib/format'

/**
 * Downloads per day as bars, drawn as SVG with attributes and classes only:
 * the Content-Security-Policy refuses `style` attributes. The chart is
 * hidden from screen readers, who get the table next to it.
 */
export function BarChart({
  data,
  label,
}: {
  data: { day: string; count: number }[]
  label: string
}) {
  const width = 600
  const height = 160
  const top = 10
  const bottom = 20
  const max = Math.max(1, ...data.map((d) => d.count))
  const slot = width / Math.max(1, data.length)
  const bar = Math.max(2, slot * 0.7)
  const plot = height - top - bottom
  const first = data[0]
  const last = data[data.length - 1]

  return (
    <figure className="grid gap-2">
      <svg
        viewBox={`0 0 ${width} ${height}`}
        className="h-44 w-full"
        role="img"
        aria-label={label}
        preserveAspectRatio="none"
      >
        <line
          x1={0}
          x2={width}
          y1={top}
          y2={top}
          className="stroke-chart-grid"
          strokeDasharray="4 4"
        />
        <line x1={0} x2={width} y1={top + plot} y2={top + plot} className="stroke-chart-grid" />
        {data.map((d, index) => {
          const h = (d.count / max) * plot
          return (
            <rect
              key={d.day}
              x={index * slot + (slot - bar) / 2}
              y={top + plot - h}
              width={bar}
              height={Math.max(h, d.count > 0 ? 1 : 0)}
              rx={1.5}
              className="fill-chart-bar"
            >
              <title>{`${formatDate(d.day)}: ${formatNumber(d.count)}`}</title>
            </rect>
          )
        })}
      </svg>
      <figcaption className="flex justify-between text-xs text-muted-foreground">
        <span>{first ? formatDate(first.day) : ''}</span>
        <span>max {formatNumber(max)} / day</span>
        <span>{last ? formatDate(last.day) : ''}</span>
      </figcaption>
    </figure>
  )
}
