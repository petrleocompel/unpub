import { KeyRound } from 'lucide-react'
import { useId, type ReactNode } from 'react'
import { CopyButton } from '@/components/copy-button'

/**
 * A secret shown once: a new API token or webhook secret. It lives in the
 * state of the page that created it, so navigating away forgets it. Drawn
 * as the warning-toned box of board 01.
 */
export function SecretBox({
  title,
  secret,
  label,
  children,
}: {
  title: string
  secret: string
  label: string
  children?: ReactNode
}) {
  const titleId = useId()
  return (
    <section
      aria-labelledby={titleId}
      role="status"
      className="grid grid-cols-[minmax(0,1fr)] gap-3 rounded-lg border-[1.5px] border-warning/60 bg-[color-mix(in_oklab,var(--warning)_8%,var(--card))] px-4.5 py-4"
    >
      <div className="flex items-start gap-3">
        <KeyRound aria-hidden className="mt-0.5 size-4 shrink-0 text-warning" />
        <div className="grid gap-0.5">
          <h3 id={titleId} className="text-sm font-semibold">
            {title}
          </h3>
          <p className="text-[0.8125rem] text-muted-foreground">
            <strong className="font-medium text-foreground">Copy it now.</strong> It will not be
            shown again: only a hash of it is stored.
          </p>
        </div>
      </div>
      <div className="flex items-center gap-2 rounded-md border bg-background py-1.5 pr-1.5 pl-3 font-mono text-[0.84375rem]">
        <span className="min-w-0 flex-1 truncate select-all">{secret}</span>
        <CopyButton text={secret} label={label} size="sm" variant="default" />
      </div>
      {children}
    </section>
  )
}
