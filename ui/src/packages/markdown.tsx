import { useEffect, useRef, useState } from 'react'
import { cn } from '@/lib/utils'

type Heading = { id: string; text: string; level: number }

/**
 * README or CHANGELOG HTML, rendered and sanitized by the server through an
 * allowlist (no scripts, styles or event handlers), so it is inserted as is.
 * With [toc], an "On this page" table of contents of its headings on wide
 * screens, marking the section in view (board 04).
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
  const [active, setActive] = useState<string | null>(null)

  useEffect(() => {
    const root = ref.current
    if (!root) return
    const elements = [...root.querySelectorAll<HTMLHeadingElement>('h1[id], h2[id], h3[id]')]
    // A "#" after the section headings, linking to themselves. Decorative:
    // the table of contents is the way to the sections for every reader.
    for (const element of elements) {
      if (element.tagName === 'H3' || element.querySelector(':scope > a[data-anchor]')) continue
      const anchor = document.createElement('a')
      anchor.href = `#${element.id}`
      anchor.textContent = '#'
      anchor.dataset.anchor = ''
      anchor.setAttribute('aria-hidden', 'true')
      anchor.tabIndex = -1
      element.append(' ', anchor)
    }
    if (!toc) return
    const found = elements.map((element) => ({
      id: element.id,
      text: [...element.childNodes]
        .filter((node) => !(node instanceof HTMLElement && node.dataset.anchor !== undefined))
        .map((node) => node.textContent)
        .join('')
        .trim(),
      level: Number(element.tagName.slice(1)),
    }))
    setHeadings(found.filter((heading) => heading.text))
  }, [html, toc])

  const showToc = toc && headings.length >= 3

  // The section in view: the last heading above the upper third.
  useEffect(() => {
    const root = ref.current
    if (!showToc || !root || typeof IntersectionObserver === 'undefined') return
    const visible = new Set<string>()
    const observer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (entry.isIntersecting) visible.add(entry.target.id)
          else visible.delete(entry.target.id)
        }
        const first = headings.find((heading) => visible.has(heading.id))
        if (first) setActive(first.id)
      },
      { rootMargin: '-64px 0px -66% 0px' },
    )
    for (const heading of headings) {
      const element = document.getElementById(heading.id)
      if (element && root.contains(element)) observer.observe(element)
    }
    return () => observer.disconnect()
  }, [headings, showToc])

  const top = Math.min(...headings.map((heading) => heading.level))
  const current = active ?? headings[0]?.id

  return (
    <div className={cn('grid gap-10', showToc && 'xl:grid-cols-[minmax(0,1fr)_12.5rem]')}>
      <div
        ref={ref}
        className="markdown min-w-0"
        aria-label={label}
        role="document"
        // Sanitized by the server, see Package.readmeHtml in docs/openapi.yaml.
        dangerouslySetInnerHTML={{ __html: html }}
      />
      {showToc && (
        <nav aria-label="On this page" className="hidden xl:block">
          <div className="sticky top-20 grid gap-0.5 border-l pl-0.5 text-[0.8125rem]">
            <p className="px-3 pb-1.5 text-xs font-semibold tracking-[0.06em] text-muted-foreground uppercase">
              On this page
            </p>
            <ul className="grid gap-0.5">
              {headings.map((heading) => (
                <li key={heading.id}>
                  <a
                    href={`#${heading.id}`}
                    aria-current={heading.id === current ? 'location' : undefined}
                    onClick={() => setActive(heading.id)}
                    className={cn(
                      '-ml-[3px] line-clamp-2 border-l-2 border-transparent py-[3px] pr-1 pl-3 text-muted-foreground hover:text-foreground',
                      'aria-[current]:border-primary aria-[current]:font-medium aria-[current]:text-foreground',
                      heading.level - top === 1 && 'pl-6',
                      heading.level - top >= 2 && 'pl-9',
                    )}
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
