import { screen, within } from '@testing-library/react'
import { http, HttpResponse } from 'msw'
import { describe, expect, it } from 'vitest'
import { keyInSection, settingDays } from '@/pages/admin/settings'
import * as f from '../fixtures'
import { renderApp } from '../render'
import { server, url } from '../server'

describe('admin settings', () => {
  it('shows every key with its environment variable, secrets redacted', async () => {
    server.use(
      http.get(url('/webapi/settings'), () =>
        HttpResponse.json({
          configured: true,
          sections: [
            {
              name: 'server',
              settings: [
                {
                  key: 'server.publicUrl',
                  value: 'https://pub.company.example',
                  env: 'UNPUB_SERVER_PUBLIC_URL',
                },
              ],
            },
            {
              name: 'storage',
              settings: [
                {
                  key: 'storage.s3.secretKey',
                  value: '<redacted>',
                  env: 'UNPUB_STORAGE_S3_SECRET_KEY',
                },
              ],
            },
          ],
        }),
      ),
    )
    renderApp('/admin/settings', { me: f.me() })
    const server_ = await screen.findByRole('region', { name: 'server' })
    const term = within(server_).getByRole('term')
    expect(term).toHaveTextContent('publicUrl')
    expect(term).toHaveTextContent('Environment variable UNPUB_SERVER_PUBLIC_URL')
    expect(within(server_).getByRole('definition')).toHaveTextContent('https://pub.company.example')
    expect(
      within(server_).getByRole('button', { name: 'Copy UNPUB_SERVER_PUBLIC_URL' }),
    ).toBeInTheDocument()

    const storage = screen.getByRole('region', { name: 'storage' })
    expect(within(storage).getByRole('term')).toHaveTextContent('s3.secretKey')
    expect(within(storage).getByRole('definition')).toHaveTextContent('redacted')
    expect(within(storage).queryByText('<redacted>')).toBeNull()
    expect(screen.getByText(/Secrets are redacted/)).toHaveTextContent(
      'for example UNPUB_SERVER_PUBLIC_URL',
    )
  })

  it('names a key within its section', () => {
    expect(keyInSection('server', 'server.publicUrl')).toBe('publicUrl')
    expect(keyInSection('storage', 'storage.s3.bucket')).toBe('s3.bucket')
    expect(keyInSection('auth', 'other.key')).toBe('other.key')
  })

  it('reads a number of days from the settings', () => {
    const settings = (value: string) => ({
      configured: true,
      sections: [
        {
          name: 'audit',
          settings: [{ key: 'audit.retentionDays', value, env: 'UNPUB_AUDIT_RETENTION_DAYS' }],
        },
      ],
    })
    expect(settingDays(settings('90'), 'audit.retentionDays')).toBe(90)
    expect(settingDays(settings('0 (kept forever)'), 'audit.retentionDays')).toBe(0)
    expect(settingDays(settings('90'), 'webhooks.retentionDays')).toBeNull()
    expect(settingDays(undefined, 'audit.retentionDays')).toBeNull()
  })
})
