import { KeyRound } from 'lucide-react'
import { useId, type ReactNode } from 'react'
import { CodeBlock } from '@/components/copy-button'

/**
 * A secret shown once: a new API token or webhook secret. It lives in the
 * state of the page that created it, so navigating away forgets it.
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
      className="grid gap-3 rounded-lg border-2 border-primary/60 bg-primary/5 p-4"
    >
      <h3 id={titleId} className="flex items-center gap-2 font-semibold">
        <KeyRound aria-hidden className="size-4 text-primary" />
        {title}
      </h3>
      <p className="text-sm">
        <strong>Copy it now.</strong> It will not be shown again: only a hash of it is stored.
      </p>
      <CodeBlock code={secret} label={label} />
      {children}
    </section>
  )
}
