import { act, screen, waitFor } from '@testing-library/react'
import { http, HttpResponse } from 'msw'
import { describe, expect, it } from 'vitest'
import * as f from '../fixtures'
import { renderApp, where } from '../render'
import { server, url } from '../server'

function handlers() {
  server.use(
    http.get(url('/webapi/v2/packages'), () =>
      HttpResponse.json(f.page([f.summary('my_company_core')])),
    ),
    http.get(url('/webapi/package/:name'), () => HttpResponse.json({ data: f.pkg() })),
    http.get(url('/webapi/users'), () => HttpResponse.json(f.page([f.admin], 1, 50))),
    http.get(url('/webapi/audit'), () => HttpResponse.json(f.page([], 1, 50))),
  )
}

const main = () => document.getElementById('main')

describe('focus on navigation', () => {
  it('leaves the focus alone on the first page', async () => {
    handlers()
    renderApp('/packages')
    await screen.findByRole('link', { name: 'my_company_core' })
    expect(document.body).toHaveFocus()
  })

  it('moves it to the main landmark of a new page', async () => {
    handlers()
    const { user, router } = renderApp('/packages')
    await user.click(await screen.findByRole('link', { name: 'my_company_core' }))
    await screen.findByRole('heading', { level: 1, name: /^my_company_core/ })
    expect(where(router)).toBe('/packages/my_company_core')
    // Also once the loading skeleton gives way to the page.
    await waitFor(() => expect(main()).toHaveFocus())
    expect(main()).toHaveAttribute('tabindex', '-1')
  })

  it('keeps it on a change of the query alone', async () => {
    handlers()
    const { user } = renderApp('/packages/my_company_core')
    await screen.findByRole('heading', { level: 1, name: /^my_company_core/ })
    const tab = screen.getByRole('tab', { name: 'Versions' })
    await user.click(tab)
    expect(screen.getByRole('tab', { name: 'Versions', selected: true })).toHaveFocus()
  })

  it('moves it on a page that loads on demand', async () => {
    handlers()
    const { router } = renderApp('/packages', { me: f.me() })
    await screen.findByRole('link', { name: 'my_company_core' })
    await act(() => router.navigate('/admin/users'))
    await screen.findByRole('heading', { level: 1, name: 'Users' })
    await waitFor(() => expect(main()).toHaveFocus())

    await act(() => router.navigate('/admin/audit'))
    await screen.findByRole('heading', { level: 1, name: 'Audit log' })
    await waitFor(() => expect(main()).toHaveFocus())
  })
})
