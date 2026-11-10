import { render, screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import { Tabs, TabsList, TabsTrigger } from '@/components/ui/tabs'

describe('the line tabs', () => {
  it('draws the focus ring of a line tab inside it, as the row scrolls', () => {
    render(
      <Tabs value="c">
        <TabsList variant="line" aria-label="Tabs">
          <TabsTrigger value="c">C</TabsTrigger>
        </TabsList>
      </Tabs>,
    )
    expect(screen.getByRole('tablist')).toHaveClass('overflow-x-auto')
    expect(screen.getByRole('tab', { name: 'C' })).toHaveClass(
      'group-data-[variant=line]/tabs-list:focus-visible:-outline-offset-2',
    )
  })
})
