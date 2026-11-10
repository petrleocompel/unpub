import { useEffect, useRef, useState } from 'react'
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

/**
 * Copies [text], toasting the result. [label] names what is copied. The
 * text sizes ('xs', 'sm') say "Copy", then "Copied" with a check.
 */
export function CopyButton({
  text,
  label,
  className,
  size = 'icon-sm',
  variant = 'ghost',
}: {
  text: string
  label: string
  className?: string
  size?: 'icon-sm' | 'icon-xs' | 'sm' | 'xs'
  /** 'default' is the primary button of the one-shot secret. */
  variant?: 'ghost' | 'default'
}) {
  const [copied, setCopied] = useState(false)
  // "Copied" for 2 s; a new copy restarts it, unmounting cancels it.
  const timer = useRef<number | undefined>(undefined)
  useEffect(() => () => window.clearTimeout(timer.current), [])
  const withText = size === 'sm' || size === 'xs'
  return (
    <Button
      type="button"
      variant={variant}
      size={size}
      className={cn(
        'shrink-0',
        variant === 'ghost' && 'text-muted-foreground hover:text-foreground',
        className,
      )}
      aria-label={`Copy ${label}`}
      title={`Copy ${label}`}
      onClick={async () => {
        if (await copyText(text)) {
          setCopied(true)
          toast.success('Copied to the clipboard', label)
          window.clearTimeout(timer.current)
          timer.current = window.setTimeout(() => setCopied(false), 2000)
        } else {
          toast.error('Could not copy', 'Select the text and copy it by hand.')
        }
      }}
    >
      {copied ? (
        <Check aria-hidden className={cn(variant === 'ghost' && 'text-success')} />
      ) : (
        <Copy aria-hidden />
      )}
      {withText && (
        <span className={cn(variant === 'ghost' && 'text-foreground')}>
          {copied ? 'Copied' : 'Copy'}
        </span>
      )}
    </Button>
  )
}

/**
 * A block of code or a command with a copy button (board 01). With [title]
 * a header names it ("Dart", "pubspec.yaml") and holds the button; with
 * [prompt] every line starts with a `$ ` that is not copied.
 */
export function CodeBlock({
  code,
  label,
  title,
  prompt = false,
  className,
}: {
  code: string
  label: string
  title?: string
  prompt?: boolean
  className?: string
}) {
  const body = (
    <pre
      className={cn(
        'overflow-x-auto px-3.5 py-3 font-mono text-[0.8125rem] leading-[1.3125rem] text-foreground',
        !title && 'pr-12',
      )}
    >
      <code>
        {prompt
          ? code.split('\n').map((line, index) => (
              <span key={index} className="block">
                <span aria-hidden className="text-muted-foreground select-none">
                  ${' '}
                </span>
                {line}
              </span>
            ))
          : code}
      </code>
    </pre>
  )
  return (
    <div className={cn('relative min-w-0 rounded-lg border bg-code text-left', className)}>
      {title ? (
        <>
          <div className="flex items-center justify-between gap-2 border-b py-1.5 pr-1.5 pl-3.5 text-xs font-medium text-muted-foreground">
            <span>{title}</span>
            <CopyButton text={code} label={label} size="xs" />
          </div>
          {body}
        </>
      ) : (
        <>
          {body}
          <CopyButton text={code} label={label} className="absolute top-[7px] right-[7px]" />
        </>
      )}
    </div>
  )
}

/** A hash shortened to 12 characters, with a copy button for the whole. */
export function HashText({ hash, label = 'SHA-256' }: { hash: string; label?: string }) {
  return (
    <span className="inline-flex items-center gap-1 font-mono text-xs text-muted-foreground">
      <code title={hash}>{hash.slice(0, 12)}</code>
      <CopyButton text={hash} label={label} size="icon-xs" className="size-5.5" />
    </span>
  )
}
