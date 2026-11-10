import { act, fireEvent, screen, waitFor } from '@testing-library/react'
import { http, HttpResponse } from 'msw'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { searchDebounceMs } from '@/layout/search-box'
import * as f from '../fixtures'
import { renderApp, where } from '../render'
import { server, url } from '../server'

function handlers() {
  server.use(
    http.get(url('/webapi/v2/packages'), () =>
      HttpResponse.json(f.page([f.summary('my_company_core')])),
    ),
    http.get(url('/webapi/package/:name'), () => HttpResponse.json({ data: f.pkg() })),
    http.get(url('/webapi/tokens'), () => HttpResponse.json(f.page([f.token()]))),
  )
}

afterEach(() => {
  vi.useRealTimers()
})

describe('search box', () => {
  it('drops a search still being typed when the user navigates', async () => {
    handlers()
    const { router } = renderApp('/packages?sort=name')
    const link = await screen.findByRole('link', { name: 'my_company_core' })
    vi.useFakeTimers()
    fireEvent.change(screen.getByRole('searchbox', { name: 'Search packages' }), {
      target: { value: 'co' },
    })
    fireEvent.click(link)
    await act(async () => {
      await vi.advanceTimersByTimeAsync(searchDebounceMs * 3)
    })
    vi.useRealTimers()
    await waitFor(() => expect(where(router)).toBe('/packages/my_company_core'))
    expect(
      await screen.findByRole('heading', { level: 1, name: /my_company_core/ }),
    ).toBeInTheDocument()
    expect(where(router)).toBe('/packages/my_company_core')
  })

  it('keeps the other parameters of the list when it commits', async () => {
    handlers()
    const { router } = renderApp('/packages?sort=name')
    await screen.findByRole('link', { name: 'my_company_core' })
    vi.useFakeTimers()
    fireEvent.change(screen.getByRole('searchbox', { name: 'Search packages' }), {
      target: { value: 'co' },
    })
    // A filter chosen while the search waits stays.
    await act(() => router.navigate('/packages?sort=name&sdk=flutter'))
    fireEvent.change(screen.getByRole('searchbox', { name: 'Search packages' }), {
      target: { value: 'core' },
    })
    await act(async () => {
      await vi.advanceTimersByTimeAsync(searchDebounceMs * 3)
    })
    vi.useRealTimers()
    await waitFor(() => expect(where(router)).toBe('/packages?sort=name&sdk=flutter&q=core'))
  })

  it('focuses the search with / elsewhere', async () => {
    handlers()
    renderApp('/packages')
    await screen.findByRole('link', { name: 'my_company_core' })
    expect(fireEvent.keyDown(document.body, { key: '/' })).toBe(false)
    expect(screen.getByRole('searchbox', { name: 'Search packages' })).toHaveFocus()
  })
})
