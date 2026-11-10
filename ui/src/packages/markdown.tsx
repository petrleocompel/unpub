import { useEffect, useRef, useState } from 'react'
import { cn } from '@/lib/utils'

type Heading = { id: string; text: string; level: number }

/** The top of the strip the table of contents watches, below the header. */
const stripTop = 64

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

  // The section in view: the first heading in the strip below the header
  // and above the lower two thirds, else the last heading above that strip,
  // as after a jump into the middle of a long section.
  useEffect(() => {
    const root = ref.current
    if (!showToc || !root || typeof IntersectionObserver === 'undefined') return
    const elements = headings
      .map((heading) => document.getElementById(heading.id))
      .filter((element): element is HTMLElement => !!element && root.contains(element))
    const visible = new Set<string>()
    const update = () => {
      const first = elements.find((element) => visible.has(element.id))
      if (first) return setActive(first.id)
      const above = elements.filter((element) => element.getBoundingClientRect().top < stripTop)
      setActive((above[above.length - 1] ?? elements[0])?.id ?? null)
    }
    const observer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (entry.isIntersecting) visible.add(entry.target.id)
          else visible.delete(entry.target.id)
        }
        update()
      },
      { rootMargin: `-${stripTop}px 0px -66% 0px` },
    )
    for (const element of elements) observer.observe(element)
    // A jump can pass over every heading, which the observer does not
    // report; the positions tell the section then.
    const onScroll = () => {
      if (visible.size === 0) update()
    }
    window.addEventListener('scroll', onScroll, { passive: true })
    return () => {
      observer.disconnect()
      window.removeEventListener('scroll', onScroll)
    }
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
