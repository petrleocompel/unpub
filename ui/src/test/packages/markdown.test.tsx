import { act, fireEvent, render, screen, within } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { Markdown } from '@/packages/markdown'

/** An IntersectionObserver the test drives by hand. */
class FakeObserver {
  static last: FakeObserver | null = null
  readonly observed: Element[] = []
  constructor(
    readonly callback: IntersectionObserverCallback,
    readonly options?: IntersectionObserverInit,
  ) {
    FakeObserver.last = this
  }
  observe(element: Element) {
    this.observed.push(element)
  }
  unobserve() {}
  disconnect() {
    this.observed.length = 0
  }
  takeRecords() {
    return []
  }
  /** Reports [changes], heading id to whether it is in the strip. */
  report(changes: Record<string, boolean>) {
    const entries = Object.entries(changes).map(
      ([id, isIntersecting]) =>
        ({
          target: document.getElementById(id)!,
          isIntersecting,
        }) as unknown as IntersectionObserverEntry,
    )
    act(() => this.callback(entries, this as unknown as IntersectionObserver))
  }
}

/** Places the headings at the viewport tops in [tops], heading id to px. */
function place(tops: Record<string, number>) {
  for (const [id, top] of Object.entries(tops)) {
    document.getElementById(id)!.getBoundingClientRect = () =>
      ({ top, bottom: top + 30, left: 0, right: 0, width: 0, height: 30 }) as DOMRect
  }
}

const html =
  '<h1 id="md-intro">Intro</h1><p>Hello.</p>' +
  '<h2 id="md-usage">Usage</h2><p>A long section.</p>' +
  '<h2 id="md-api">API</h2><p>More.</p>' +
  '<h2 id="md-license">License</h2><p>BSD.</p>'

function renderToc() {
  render(<Markdown html={html} toc label="README" />)
  const toc = screen.getByRole('navigation', { name: 'On this page' })
  const current = () =>
    within(toc)
      .getAllByRole('link')
      .filter((link) => link.getAttribute('aria-current') === 'location')
      .map((link) => link.textContent)
  return { toc, current, observer: FakeObserver.last! }
}

describe('the table of contents', () => {
  beforeEach(() => {
    FakeObserver.last = null
    vi.stubGlobal('IntersectionObserver', FakeObserver)
  })
  afterEach(() => vi.unstubAllGlobals())

  it('marks the first heading before anything is reported', () => {
    const { current, observer } = renderToc()
    expect(current()).toEqual(['Intro'])
    expect(observer.observed.map((element) => element.id)).toEqual([
      'md-intro',
      'md-usage',
      'md-api',
      'md-license',
    ])
    expect(observer.options?.rootMargin).toBe('-64px 0px -66% 0px')
  })

  it('marks the first heading in the strip', () => {
    const { current, observer } = renderToc()
    observer.report({ 'md-usage': true, 'md-api': true })
    expect(current()).toEqual(['Usage'])
    observer.report({ 'md-usage': false })
    expect(current()).toEqual(['API'])
  })

  it('marks the section of a jump into its middle, its heading above the viewport', () => {
    const { current, observer } = renderToc()
    observer.report({ 'md-intro': true })
    expect(current()).toEqual(['Intro'])

    // Down into the middle of Usage: Intro leaves the strip, nothing enters.
    place({ 'md-intro': -1400, 'md-usage': -600, 'md-api': 900, 'md-license': 1600 })
    observer.report({ 'md-intro': false })
    expect(current()).toEqual(['Usage'])
  })

  it('follows a jump that passes over every heading', () => {
    const { current, observer } = renderToc()
    place({ 'md-intro': -1400, 'md-usage': -600, 'md-api': 900, 'md-license': 1600 })
    observer.report({ 'md-intro': false })
    expect(current()).toEqual(['Usage'])

    // The observer reports nothing: no heading was in the strip before or after.
    place({ 'md-intro': -3000, 'md-usage': -2200, 'md-api': -700, 'md-license': 900 })
    fireEvent.scroll(window)
    expect(current()).toEqual(['API'])

    // Back to the top, above every heading.
    place({ 'md-intro': 120, 'md-usage': 600, 'md-api': 1400, 'md-license': 2000 })
    fireEvent.scroll(window)
    expect(current()).toEqual(['Intro'])
  })

  it('leaves the scroll position to the observer while a heading is in the strip', () => {
    const { current, observer } = renderToc()
    observer.report({ 'md-api': true })
    place({ 'md-intro': -3000, 'md-usage': -2200, 'md-api': 100, 'md-license': 900 })
    fireEvent.scroll(window)
    expect(current()).toEqual(['API'])
  })

  it('marks a heading picked in the table of contents', () => {
    const { toc, current } = renderToc()
    fireEvent.click(within(toc).getByRole('link', { name: 'License' }))
    expect(current()).toEqual(['License'])
  })

  it('stops watching when it goes away', () => {
    const { unmount } = render(<Markdown html={html} toc label="README" />)
    const observer = FakeObserver.last!
    const disconnect = vi.spyOn(observer, 'disconnect')
    const remove = vi.spyOn(window, 'removeEventListener')
    unmount()
    expect(disconnect).toHaveBeenCalled()
    expect(remove).toHaveBeenCalledWith('scroll', expect.any(Function))
    remove.mockRestore()
  })
})
