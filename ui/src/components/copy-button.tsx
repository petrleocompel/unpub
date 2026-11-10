import { useState } from 'react'
import { Check, Copy } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { toast } from '@/lib/toast'
import { cn } from '@/lib/utils'

export async function copyText(text: string) {
  try {
    await navigator.clipboard.writeText(text)
    return true
  } catch {
    return false
  }
}

/** Copies [text], toasting the result. [label] names what is copied. */
export function CopyButton({
  text,
  label,
  className,
  size = 'icon-sm',
}: {
  text: string
  label: string
  className?: string
  size?: 'icon-sm' | 'icon-xs' | 'sm'
}) {
  const [copied, setCopied] = useState(false)
  return (
    <Button
      type="button"
      variant="ghost"
      size={size}
      className={cn('shrink-0', className)}
      aria-label={`Copy ${label}`}
      title={`Copy ${label}`}
      onClick={async () => {
        if (await copyText(text)) {
          setCopied(true)
          toast.success('Copied to the clipboard', label)
          window.setTimeout(() => setCopied(false), 2000)
        } else {
          toast.error('Could not copy', 'Select the text and copy it by hand.')
        }
      }}
    >
      {copied ? <Check aria-hidden /> : <Copy aria-hidden />}
      {size === 'sm' && (copied ? 'Copied' : 'Copy')}
    </Button>
  )
}

/** A block of code or a command with a copy button. */
export function CodeBlock({
  code,
  label,
  className,
}: {
  code: string
  label: string
  className?: string
}) {
  return (
    <div className={cn('relative flex items-start gap-2 rounded-lg border bg-code p-3', className)}>
      <pre className="min-w-0 flex-1 overflow-x-auto font-mono text-sm leading-6">
        <code>{code}</code>
      </pre>
      <CopyButton text={code} label={label} />
    </div>
  )
}

/** A hash shortened to 12 characters, with a copy button for the whole. */
export function HashText({ hash, label = 'SHA-256' }: { hash: string; label?: string }) {
  return (
    <span className="inline-flex items-center gap-1">
      <code className="font-mono text-xs" title={hash}>
        {hash.slice(0, 12)}
      </code>
      <CopyButton text={hash} label={label} size="icon-xs" />
    </span>
  )
}
