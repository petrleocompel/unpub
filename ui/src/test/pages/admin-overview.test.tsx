import { screen, within } from '@testing-library/react'
import { http, HttpResponse } from 'msw'
import { describe, expect, it } from 'vitest'
import * as f from '../fixtures'
import { renderApp } from '../render'
import { server, url } from '../server'

describe('admin overview', () => {
  it('shows readiness, counts and recent publishes', async () => {
    server.use(
      http.get(url('/webapi/admin/overview'), () =>
        HttpResponse.json(
          f.overview({
            failedDeliveriesLast24h: 3,
            readiness: {
              status: 'unavailable',
              checks: {
                mongo: { status: 'ok' },
                storage: { status: 'error', error: 'disk full' },
              },
            },
          }),
        ),
      ),
    )
    renderApp('/admin', { me: f.me() })
    expect(await screen.findByText('MongoDB ready')).toBeInTheDocument()
    expect(screen.getByText('Storage not ready')).toHaveAttribute('title', 'disk full')
    expect(screen.getByRole('link', { name: /Packages\s*12/ })).toHaveAttribute(
      'href',
      '/admin/packages',
    )
    expect(screen.getByText('3 failed in 24 h')).toBeInTheDocument()
    expect(screen.getByText('3 failed')).toBeInTheDocument()

    const publishes = screen.getByRole('table', { name: /last publishes/ })
    expect(within(publishes).getByRole('link', { name: 'my_company_core' })).toHaveAttribute(
      'href',
      '/admin/packages/my_company_core',
    )
    expect(within(publishes).getByText(/jane.doe@company.example · token/)).toBeInTheDocument()

    // The sidebar counts the same failures on Webhooks.
    const nav = screen.getByRole('navigation', { name: 'Administration sections' })
    expect(
      within(nav).getByRole('link', { name: 'Webhooks, 3 failed deliveries in 24 h' }),
    ).toHaveAttribute('href', '/admin/webhooks')
    expect(within(nav).getByRole('link', { name: 'Overview' })).toHaveAttribute(
      'aria-current',
      'page',
    )
  })

  it('leaves the webhooks out when they are switched off', async () => {
    renderApp('/admin', {
      me: f.me(),
      config: f.config({
        features: { metrics: false, webhooks: false, spa: true, classic: true },
      }),
    })
    await screen.findByText('MongoDB ready')
    const nav = screen.getByRole('navigation', { name: 'Administration sections' })
    expect(within(nav).queryByRole('link', { name: /Webhooks/ })).toBeNull()
    expect(within(nav).queryByRole('link', { name: /Metrics/ })).toBeNull()
    expect(screen.queryByRole('heading', { name: /Failed deliveries/ })).toBeNull()
  })
})
