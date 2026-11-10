import { useEffect, useRef, useState } from 'react'
import { cn } from '@/lib/utils'

type Heading = { id: string; text: string; level: number }

/**
 * README or CHANGELOG HTML, rendered and sanitized by the server through an
 * allowlist (no scripts, styles or event handlers), so it is inserted as is.
 * With [toc], a table of contents of its headings on wide screens.
 */
export function Markdown({
  html,
  toc = false,
  label,
}: {
  html: string
  toc?: boolean
  label: string
}) {
  const ref = useRef<HTMLDivElement>(null)
  const [headings, setHeadings] = useState<Heading[]>([])

  useEffect(() => {
    if (!toc || !ref.current) return
    const found = [
      ...ref.current.querySelectorAll<HTMLHeadingElement>('h1[id], h2[id], h3[id]'),
    ].map((element) => ({
      id: element.id,
      text: element.textContent?.trim() ?? '',
      level: Number(element.tagName.slice(1)),
    }))
    setHeadings(found.filter((heading) => heading.text))
  }, [html, toc])

  const showToc = toc && headings.length >= 3
  const top = Math.min(...headings.map((heading) => heading.level))

  return (
    <div className={cn('grid gap-8', showToc && 'xl:grid-cols-[minmax(0,1fr)_14rem]')}>
      <div
        ref={ref}
        className="markdown min-w-0"
        aria-label={label}
        role="document"
        // Sanitized by the server, see Package.readmeHtml in docs/openapi.yaml.
        dangerouslySetInnerHTML={{ __html: html }}
      />
      {showToc && (
        <nav aria-label="Table of contents" className="hidden xl:block">
          <div className="sticky top-20 grid gap-2 text-sm">
            <p className="font-semibold">On this page</p>
            <ul className="grid gap-1.5 border-l">
              {headings.map((heading) => (
                <li
                  key={heading.id}
                  className={cn(
                    '-ml-px border-l border-transparent pl-3',
                    heading.level - top === 1 && 'pl-6',
                    heading.level - top >= 2 && 'pl-9',
                  )}
                >
                  <a
                    href={`#${heading.id}`}
                    className="line-clamp-2 text-muted-foreground hover:text-foreground"
                  >
                    {heading.text}
                  </a>
                </li>
              ))}
            </ul>
          </div>
        </nav>
      )}
    </div>
  )
}
