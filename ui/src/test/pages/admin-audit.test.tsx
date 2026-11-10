import { screen, waitFor, within } from '@testing-library/react'
import { http, HttpResponse } from 'msw'
import { describe, expect, it } from 'vitest'
import * as f from '../fixtures'
import { renderApp, where } from '../render'
import { server, url } from '../server'

function auditApi() {
  const queries: URLSearchParams[] = []
  server.use(
    http.get(url('/webapi/audit'), ({ request }) => {
      const params = new URL(request.url).searchParams
      queries.push(params)
      return HttpResponse.json(
        f.page(
          [
            f.auditEvent(),
            f.auditEvent({
              action: 'user.created',
              package: null,
              version: null,
              target: 'new@company.example',
              details: {},
            }),
          ],
          Number(params.get('page') ?? 1),
          50,
          120,
        ),
      )
    }),
    http.get(url('/webapi/settings'), () =>
      HttpResponse.json({
        configured: true,
        sections: [
          {
            name: 'audit',
            settings: [
              { key: 'audit.retentionDays', value: '90', env: 'UNPUB_AUDIT_RETENTION_DAYS' },
            ],
          },
        ],
      }),
    ),
  )
  return queries
}

describe('audit log', () => {
  it('filters through the URL and the request', async () => {
    const queries = auditApi()
    const { user, router } = renderApp('/admin/audit', { me: f.me() })
    expect(await screen.findByText(/kept for 90 days/)).toBeInTheDocument()
    await screen.findByRole('cell', { name: 'user.created' })

    const form = screen.getByRole('form', { name: 'Filter the audit log' })
    await user.selectOptions(within(form).getByLabelText('Action'), 'package.published')
    await user.type(within(form).getByLabelText('Actor'), 'jane.doe@company.example')
    await user.type(within(form).getByLabelText('Package'), 'my_company_core')
    await user.type(within(form).getByLabelText('From'), '2026-11-01')
    await user.click(within(form).getByRole('button', { name: 'Filter' }))

    expect(where(router)).toBe(
      '/admin/audit?action=package.published&actor=jane.doe%40company.example&package=my_company_core&from=2026-11-01',
    )
    await waitFor(() => {
      const last = queries.at(-1)!
      expect(last.get('action')).toBe('package.published')
      expect(last.get('actor')).toBe('jane.doe@company.example')
      expect(last.get('package')).toBe('my_company_core')
      expect(last.get('from')).toBe('2026-11-01')
      expect(last.get('size')).toBe('50')
    })

    await user.click(screen.getByRole('button', { name: 'Reset' }))
    expect(where(router)).toBe('/admin/audit')
  })

  it('pages, links targets and expands details', async () => {
    const queries = auditApi()
    const { user, router } = renderApp('/admin/audit?action=user.created', { me: f.me() })
    await screen.findByRole('cell', { name: 'user.created' })
    expect(screen.getByRole('link', { name: 'my_company_core 1.4.0' })).toHaveAttribute(
      'href',
      '/packages/my_company_core/versions/1.4.0',
    )
    expect(screen.getByRole('link', { name: 'new@company.example' })).toHaveAttribute(
      'href',
      '/admin/users?q=new%40company.example',
    )

    await user.click(screen.getByRole('button', { name: 'Show details' }))
    expect(screen.getByText(new RegExp(`"sha256": "${f.sha256}"`))).toBeInTheDocument()

    await user.click(screen.getByRole('link', { name: 'Page 3' }))
    expect(where(router)).toBe('/admin/audit?action=user.created&page=3')
    await waitFor(() => expect(queries.at(-1)?.get('page')).toBe('3'))
  })
})
