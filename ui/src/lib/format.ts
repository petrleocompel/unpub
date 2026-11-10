const numberFormat = new Intl.NumberFormat()
const compactFormat = new Intl.NumberFormat(undefined, { notation: 'compact' })
const dateFormat = new Intl.DateTimeFormat(undefined, { dateStyle: 'medium' })
const dateTimeFormat = new Intl.DateTimeFormat(undefined, {
  dateStyle: 'medium',
  timeStyle: 'short',
})
const relativeFormat = new Intl.RelativeTimeFormat(undefined, { numeric: 'auto' })

export function formatNumber(value: number | null | undefined) {
  return value === null || value === undefined ? '–' : numberFormat.format(value)
}

export function formatCompact(value: number) {
  return compactFormat.format(value)
}

const dateOnly = /^(\d{4})-(\d{2})-(\d{2})$/

function parse(value: string | Date) {
  const day = typeof value === 'string' ? dateOnly.exec(value) : null
  // A day such as 2026-11-10 is a local day, not midnight UTC.
  const date = day
    ? new Date(Number(day[1]), Number(day[2]) - 1, Number(day[3]))
    : value instanceof Date
      ? value
      : new Date(value)
  return Number.isNaN(date.getTime()) ? null : date
}

export function formatDate(value: string | null | undefined) {
  const date = value ? parse(value) : null
  return date ? dateFormat.format(date) : '–'
}

export function formatDateTime(value: string | null | undefined) {
  const date = value ? parse(value) : null
  return date ? dateTimeFormat.format(date) : '–'
}

const units: [Intl.RelativeTimeFormatUnit, number][] = [
  ['year', 365 * 24 * 3600],
  ['month', 30 * 24 * 3600],
  ['week', 7 * 24 * 3600],
  ['day', 24 * 3600],
  ['hour', 3600],
  ['minute', 60],
]

export function formatRelative(value: string | null | undefined, now = Date.now()) {
  const date = value ? parse(value) : null
  if (!date) return '–'
  const seconds = Math.round((date.getTime() - now) / 1000)
  for (const [unit, size] of units) {
    if (Math.abs(seconds) >= size) return relativeFormat.format(Math.round(seconds / size), unit)
  }
  return 'just now'
}

export function formatBytes(bytes: number | null | undefined) {
  if (bytes === null || bytes === undefined) return '–'
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB']
  let value = bytes
  let unit = 0
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024
    unit++
  }
  return `${value.toFixed(unit === 0 ? 0 : 1)} ${units[unit]}`
}

export function shortHash(hash: string, length = 12) {
  return hash.slice(0, length)
}

const prerelease = /^\d+\.\d+\.\d+-/

export function isPrerelease(version: string) {
  return prerelease.test(version)
}
