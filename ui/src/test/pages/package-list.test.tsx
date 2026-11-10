import { act, screen, waitFor, within } from '@testing-library/react'
import { http, HttpResponse } from 'msw'
import { describe, expect, it } from 'vitest'
import * as f from '../fixtures'
import { renderApp, where } from '../render'
import { server, url } from '../server'

/** Answers the package list, recording the query of each request. */
function packages(total = 2, names = ['my_company_core', 'my_company_log']) {
  const queries: URLSearchParams[] = []
  server.use(
    http.get(url('/webapi/v2/packages'), ({ request }) => {
      const params = new URL(request.url).searchParams
      queries.push(params)
      const page = Number(params.get('page') ?? 1)
      const size = Number(params.get('size') ?? 20)
      return HttpResponse.json(
        f.page(
          names.map((name) => f.summary(name)),
          page,
          size,
          total,
        ),
      )
    }),
  )
  return queries
}

describe('package list', () => {
  it('lists packages with their badges and downloads', async () => {
    packages()
    renderApp('/')
    expect(await screen.findByRole('link', { name: 'my_company_core' })).toHaveAttribute(
      'href',
      '/packages/my_company_core',
    )
    const list = screen.getByRole('list', { name: 'Packages' })
    expect(within(list).getAllByRole('listitem')).toHaveLength(2)
    expect(within(list).getAllByText('Dart')).toHaveLength(2)
  })

  it('searches as you type and keeps the query in the URL', async () => {
    const queries = packages()
    const { user, router } = renderApp('/packages')
    await screen.findByRole('link', { name: 'my_company_core' })

    await user.type(screen.getByRole('searchbox', { name: 'Search packages' }), 'core')
    await waitFor(() => expect(where(router)).toBe('/packages?q=core'))
    await waitFor(() => expect(queries.at(-1)?.get('q')).toBe('core'))
    expect(queries.at(-1)?.get('sort')).toBe('relevance')
    expect(screen.getByRole('heading', { level: 1 })).toHaveTextContent('Results for core')
  })

  it('focuses the search with / and clears it with Escape', async () => {
    packages()
    const { user, router } = renderApp('/packages?q=core')
    await screen.findByRole('link', { name: 'my_company_core' })
    const search = screen.getByRole('searchbox', { name: 'Search packages' })
    expect(search).toHaveValue('core')

    await user.keyboard('/')
    expect(search).toHaveFocus()
    await user.keyboard('{Escape}')
    expect(search).toHaveValue('')
    await waitFor(() => expect(where(router)).toBe('/packages'))
  })

  it('puts filters and sorting in the URL and the request', async () => {
    const queries = packages()
    const { user, router } = renderApp('/packages')
    await screen.findByRole('link', { name: 'my_company_core' })

    // Best match is only offered with a query.
    const sort = screen.getByRole('combobox', { name: 'Sort' })
    expect(within(sort).queryByRole('option', { name: 'Best match' })).toBeNull()

    await user.selectOptions(screen.getByRole('combobox', { name: 'SDK' }), 'flutter')
    await user.click(screen.getByRole('switch', { name: 'Show discontinued' }))
    await user.selectOptions(sort, 'updated')

    expect(where(router)).toBe('/packages?sdk=flutter&discontinued=1&sort=updated')
    await waitFor(() => {
      const last = queries.at(-1)
      expect(last?.get('sdk')).toBe('flutter')
      expect(last?.get('discontinued')).toBe('true')
      expect(last?.get('sort')).toBe('updated')
    })
  })

  it('goes back to the previous filters', async () => {
    packages()
    const { user, router } = renderApp('/packages')
    await screen.findByRole('link', { name: 'my_company_core' })
    await user.selectOptions(screen.getByRole('combobox', { name: 'SDK' }), 'flutter')
    await user.selectOptions(screen.getByRole('combobox', { name: 'Sort' }), 'name')
    expect(where(router)).toBe('/packages?sdk=flutter&sort=name')

    await act(() => router.navigate(-1))
    expect(where(router)).toBe('/packages?sdk=flutter')
    expect(screen.getByRole('combobox', { name: 'Sort' })).toHaveValue('downloads')
    await act(() => router.navigate(-1))
    expect(where(router)).toBe('/packages')
    expect(screen.getByRole('combobox', { name: 'SDK' })).toHaveValue('')
  })

  it('pages through the results and changes the page size', async () => {
    const queries = packages(95)
    const { user, router } = renderApp('/packages?sort=name')
    await screen.findByRole('link', { name: 'my_company_core' })
    expect(screen.getByText('1–20 of 95')).toBeInTheDocument()

    await user.click(screen.getByRole('link', { name: 'Page 5' }))
    expect(where(router)).toBe('/packages?sort=name&page=5')
    await waitFor(() => expect(queries.at(-1)?.get('page')).toBe('5'))
    expect(await screen.findByRole('link', { name: 'Page 5' })).toHaveAttribute(
      'aria-current',
      'page',
    )

    await user.selectOptions(screen.getByRole('combobox', { name: 'Per page' }), '50')
    expect(where(router)).toBe('/packages?sort=name&size=50')
    await waitFor(() => expect(queries.at(-1)?.get('size')).toBe('50'))
  })

  it('explains how to publish when the registry is empty', async () => {
    packages(0, [])
    renderApp('/')
    expect(await screen.findByRole('heading', { name: 'No packages yet' })).toBeInTheDocument()
    expect(
      screen.getByText(/dart pub publish --server https:\/\/pub\.example\.com/),
    ).toBeInTheDocument()
  })

  it('echoes the query when nothing matches and resets', async () => {
    packages(0, [])
    const { user, router } = renderApp('/packages?q=nothing&sdk=dart')
    expect(await screen.findByRole('heading', { name: 'No packages match' })).toBeInTheDocument()
    expect(screen.getByText(/Nothing matches/)).toHaveTextContent(
      'Nothing matches nothing with these filters.',
    )
    await user.click(screen.getByRole('button', { name: 'Reset the search' }))
    expect(where(router)).toBe('/packages')
  })

  it('shows the server message when the list fails', async () => {
    server.use(
      http.get(url('/webapi/v2/packages'), () =>
        HttpResponse.json(
          { error: { code: 'unavailable', message: 'MongoDB is down.' } },
          { status: 503 },
        ),
      ),
    )
    renderApp('/')
    expect(await screen.findByRole('alert')).toHaveTextContent('MongoDB is down.')
    expect(screen.getByRole('button', { name: 'Retry' })).toBeInTheDocument()
  })
})
