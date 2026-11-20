import { render, screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import { SegmentedControl } from '@/components/ui/segmented'
import { Tabs, TabsList, TabsTrigger } from '@/components/ui/tabs'

const classes = (element: Element) => [...element.classList].sort()

describe('the pill chrome', () => {
  it('is the same for the segmented control and the default tabs', () => {
    render(
      <>
        <SegmentedControl
          label="View"
          value="a"
          onValueChange={() => {}}
          options={[
            { value: 'a', label: 'A' },
            { value: 'b', label: 'B' },
          ]}
        />
        <Tabs value="c">
          <TabsList aria-label="Tabs">
            <TabsTrigger value="c">C</TabsTrigger>
            <TabsTrigger value="d">D</TabsTrigger>
          </TabsList>
        </Tabs>
      </>,
    )
    const pressed = screen.getByRole('button', { name: 'A', pressed: true })
    const selected = screen.getByRole('tab', { name: 'C', selected: true })
    expect(pressed).toHaveAttribute('data-state', 'active')
    expect(selected).toHaveAttribute('data-state', 'active')
    // The tab adds flex-1 and the vertical layout only.
    const extra = new Set(classes(selected).filter((name) => !classes(pressed).includes(name)))
    expect(classes(pressed).every((name) => classes(selected).includes(name))).toBe(true)
    expect(
      [...extra].every(
        (name) => name === 'flex-1' || name.startsWith('disabled:') || name.includes('orientation'),
      ),
    ).toBe(true)
    const track = screen.getByRole('group', { name: 'View' })
    for (const name of classes(track)) {
      expect(screen.getByRole('tablist')).toHaveClass(name)
    }
  })

  it('draws the focus ring of a line tab inside it, as the row scrolls', () => {
    render(
      <Tabs value="c">
        <TabsList variant="line" aria-label="Tabs">
          <TabsTrigger value="c">C</TabsTrigger>
        </TabsList>
      </Tabs>,
    )
    expect(screen.getByRole('tablist')).toHaveClass('overflow-x-auto')
    expect(screen.getByRole('tab', { name: 'C' })).toHaveClass('focus-visible:-outline-offset-2')
  })
})
