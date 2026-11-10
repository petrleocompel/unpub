import { screen, waitFor, within } from '@testing-library/react'
import { http, HttpResponse } from 'msw'
import { describe, expect, it } from 'vitest'
import * as f from '../fixtures'
import { renderApp } from '../render'
import { capture, server, url } from '../server'

function webhookApi() {
  server.use(
    http.get(url('/webapi/webhooks'), () =>
      HttpResponse.json({
        ...f.page([{ ...f.webhook(), deliveries: { succeeded: 3, pending: 1, failed: 2 } }], 1, 50),
        enabled: true,
      }),
    ),
    http.get(url('/webapi/webhooks/:id'), () =>
      HttpResponse.json({
        webhook: f.webhook(),
        deliveries: { succeeded: 3, pending: 1, failed: 2 },
      }),
    ),
    http.get(url('/webapi/webhooks/:id/deliveries'), () =>
      HttpResponse.json(
        f.page([
          {
            id: 'd1',
            webhookId: 'w1',
            event: 'package.published',
            eventId: 'e1',
            package: 'my_company_core',
            version: '1.4.0',
            payload: '{"id":"e1","event":"package.published","package":"my_company_core"}',
            status: 'failed',
            attempt: 5,
            nextAt: null,
            createdAt: '2026-11-01T10:00:00.000Z',
            lastAttemptAt: '2026-11-01T11:00:00.000Z',
            finishedAt: '2026-11-01T11:00:00.250Z',
            durationMs: 250,
            response: { status: 500, body: 'oops' },
            error: 'HTTP 500',
            redeliveryOf: null,
          },
        ]),
      ),
    ),
  )
}

describe('webhooks', () => {
  it('lists webhooks with their delivery counts', async () => {
    webhookApi()
    renderApp('/admin/webhooks', { me: f.me() })
    expect(
      await screen.findByRole('link', { name: 'https://ci.company.example/hook' }),
    ).toHaveAttribute('href', '/admin/webhooks/w1')
    expect(await screen.findByText('3 delivered')).toBeInTheDocument()
    expect(screen.getByText('2 failed')).toBeInTheDocument()
  })

  it('creates a webhook and shows its secret once', async () => {
    webhookApi()
    const created = capture(
      'post',
      '/webapi/webhooks',
      { webhook: f.webhook({ id: 'w2' }), secret: 'whsec_once' },
      201,
    )
    const { user } = renderApp('/admin/webhooks', { me: f.me() })
    await user.click(await screen.findByRole('button', { name: 'New webhook' }))
    const dialog = await screen.findByRole('dialog')
    await user.type(within(dialog).getByLabelText(/Payload URL/), 'https://bot.company.example/x')
    await user.click(within(dialog).getByRole('checkbox', { name: 'version.retracted' }))
    await user.click(within(dialog).getByRole('button', { name: 'Create webhook' }))

    const box = await screen.findByRole('status', { name: /signing secret/ })
    expect(within(box).getByText('whsec_once')).toBeInTheDocument()
    expect(await created[0]!.json()).toEqual({
      url: 'https://bot.company.example/x',
      events: ['package.published', 'version.retracted'],
    })
  })

  it('rotates the secret only with the box ticked, and redelivers', async () => {
    webhookApi()
    server.use(
      http.get(url('/webapi/settings'), () =>
        HttpResponse.json({
          configured: true,
          sections: [
            {
              name: 'webhooks',
              settings: [
                {
                  key: 'webhooks.retentionDays',
                  value: '30',
                  env: 'UNPUB_WEBHOOKS_RETENTION_DAYS',
                },
              ],
            },
          ],
        }),
      ),
    )
    const rotated = capture('post', '/webapi/webhooks/w1/secret', { secret: 'whsec_new' })
    const redelivered = capture('post', '/webapi/webhooks/w1/deliveries/d1/redeliver', {
      success: { message: 'Queued.' },
    })
    const { user } = renderApp('/admin/webhooks/w1', { me: f.me() })

    await user.click(await screen.findByRole('button', { name: 'Rotate secret…' }))
    const dialog = await screen.findByRole('dialog')
    const confirm = within(dialog).getByRole('button', { name: 'Rotate secret' })
    expect(confirm).toBeDisabled()
    await user.click(within(dialog).getByRole('checkbox'))
    await user.click(confirm)
    await waitFor(() => expect(rotated).toHaveLength(1))
    const box = await screen.findByRole('status', { name: /new signing secret/ })
    expect(within(box).getByText('whsec_new')).toBeInTheDocument()

    expect(await screen.findByText('HTTP 500')).toBeInTheDocument()
    expect(screen.getByText('250 ms')).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: /show the payload/ }))
    expect(document.getElementById('payload-d1')).toHaveTextContent('"package": "my_company_core"')
    expect(screen.getByText('oops')).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Redeliver' }))
    await waitFor(() => expect(redelivered).toHaveLength(1))
    expect(screen.getByText('X-Unpub-Signature: sha256=<hex>')).toBeInTheDocument()
    expect(screen.getByText('Kept 30 days')).toBeInTheDocument()
  })
})
