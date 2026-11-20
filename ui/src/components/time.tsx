import { Tooltip, TooltipContent, TooltipTrigger } from '@/components/ui/tooltip'
import { formatDate, formatDateTime, formatRelative } from '@/lib/format'

/** "3 days ago", with the absolute time in a tooltip and the datetime attribute. */
export function RelativeTime({ value }: { value: string | null | undefined }) {
  if (!value) return <span>–</span>
  return (
    <Tooltip>
      <TooltipTrigger asChild>
        {/* A button so the tooltip opens from the keyboard too. */}
        <button type="button" className="cursor-default rounded-sm whitespace-nowrap">
          <time dateTime={value}>{formatRelative(value)}</time>
        </button>
      </TooltipTrigger>
      <TooltipContent>{formatDateTime(value)}</TooltipContent>
    </Tooltip>
  )
}

/** An absolute date or time, for tables. */
export function DateTime({
  value,
  date = false,
}: {
  value: string | null | undefined
  date?: boolean
}) {
  if (!value) return <span>–</span>
  return (
    <time dateTime={value} className="whitespace-nowrap" title={formatRelative(value)}>
      {date ? formatDate(value) : formatDateTime(value)}
    </time>
  )
}
