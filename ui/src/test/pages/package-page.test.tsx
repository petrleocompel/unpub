import { act, screen, waitFor, within } from '@testing-library/react'
import { http, HttpResponse } from 'msw'
import { describe, expect, it } from 'vitest'
import * as f from '../fixtures'
import { renderApp, where } from '../render'
import { error, server, url } from '../server'

function packageHandlers(base = f.pkg()) {
  const requested: string[] = []
  server.use(
    http.get(url('/webapi/package/:name'), ({ params }) => {
      requested.push(`${params.name}`)
      return params.name === base.name
        ? HttpResponse.json({ data: base })
        : error(404, 'not_found', 'Package not found.')
    }),
    http.get(url('/webapi/package/:name/stats'), () => HttpResponse.json(f.stats(base.name))),
    http.get(url('/webapi/package/:name/:version'), ({ params }) => {
      requested.push(`${params.name}@${params.version}`)
      const version = base.versions.find((v) => v.version === params.version)
      if (!version) return error(404, 'not_found', 'Version not found.')
      return HttpResponse.json({
        data: {
          ...base,
          version: version.version,
          retracted: version.retracted,
          readmeHtml: `<h1 id="md-v">Version ${version.version}</h1>`,
        },
      })
    }),
  )
  return requested
}

describe('package page', () => {
  it('shows the header, the README with a table of contents and the sidebar', async () => {
    packageHandlers()
    renderApp('/packages/my_company_core')
    expect(
      await screen.findByRole('heading', { level: 1, name: 'my_company_core 1.4.0' }),
    ).toBeInTheDocument()
    expect(screen.getByText('1,234 downloads')).toBeInTheDocument()
    const readme = screen.getByRole('document', { name: 'README' })
    expect(within(readme).getByRole('heading', { name: 'Usage' })).toHaveAttribute('id', 'md-usage')
    const toc = await screen.findByRole('navigation', { name: 'Table of contents' })
    expect(within(toc).getByRole('link', { name: 'Usage' })).toHaveAttribute('href', '#md-usage')

    const sidebar = screen.getByRole('complementary', { name: 'Package details' })
    expect(within(sidebar).getByRole('link', { name: 'my_company_log' })).toHaveAttribute(
      'href',
      '/packages/my_company_log',
    )
    expect(within(sidebar).getByRole('link', { name: 'http' })).toHaveAttribute(
      'href',
      'https://pub.dev/packages/http',
    )
    expect(within(sidebar).getByText('^3.5.0')).toBeInTheDocument()
  })

  it('switches tabs and keeps the tab in the URL', async () => {
    packageHandlers()
    const { user, router } = renderApp('/packages/my_company_core')
    await screen.findByRole('heading', { level: 1, name: /^my_company_core/ })

    await user.click(screen.getByRole('tab', { name: 'Changelog' }))
    expect(where(router)).toBe('/packages/my_company_core?tab=changelog')
    expect(within(screen.getByRole('tabpanel')).getByText('Faster.')).toBeInTheDocument()

    await user.click(screen.getByRole('tab', { name: 'Versions' }))
    const table = within(screen.getByRole('tabpanel')).getByRole('table')
    const rows = within(table).getAllByRole('row')
    expect(rows).toHaveLength(4)
    expect(within(rows[3]!).getByText('Retracted')).toBeInTheDocument()
    expect(within(rows[1]!).getByText('Prerelease')).toBeInTheDocument()
    expect(within(rows[2]!).getByText(f.sha256.slice(0, 12))).toBeInTheDocument()
    expect(
      within(rows[2]!).getByRole('button', { name: 'Copy SHA-256 of 1.4.0' }),
    ).toBeInTheDocument()
    expect(within(rows[1]!).getByText('Not known')).toBeInTheDocument()
    expect(within(table).queryByRole('link', { name: 'Show' })).not.toBeInTheDocument()

    await user.click(screen.getByRole('tab', { name: 'Install' }))
    expect(
      screen.getByText('dart pub add my_company_core --hosted-url https://pub.example.com'),
    ).toBeInTheDocument()

    await user.click(screen.getByRole('tab', { name: 'Stats' }))
    expect(await screen.findByText('Total downloads')).toBeInTheDocument()
    expect(screen.getByRole('img', { name: /Downloads per day/ })).toBeInTheDocument()

    await user.click(screen.getByRole('tab', { name: 'README' }))
    expect(where(router)).toBe('/packages/my_company_core')
  })

  it('shows the hash of every version that has one', async () => {
    const other = 'a1b2c3d4e5f6'.padEnd(64, '0')
    packageHandlers(
      f.pkg({
        versions: [
          f.version('2.0.0-beta.3', { archiveSha256: other }),
          f.version('1.4.0', { archiveSha256: f.sha256 }),
          f.version('1.0.0', { retracted: true }),
        ],
      }),
    )
    renderApp('/packages/my_company_core?tab=versions')
    const table = await screen.findByRole('table', { name: /Versions of my_company_core/ })
    const rows = within(table).getAllByRole('row')
    expect(within(rows[1]!).getByText('a1b2c3d4e5f6')).toHaveAttribute('title', other)
    expect(
      within(rows[1]!).getByRole('button', { name: 'Copy SHA-256 of 2.0.0-beta.3' }),
    ).toBeInTheDocument()
    expect(within(rows[2]!).getByText(f.sha256.slice(0, 12))).toHaveAttribute('title', f.sha256)
    expect(within(rows[3]!).getByText('Not known')).toBeInTheDocument()
    expect(within(rows[3]!).queryByRole('button')).not.toBeInTheDocument()
    expect(within(table).queryByRole('link', { name: 'Show' })).not.toBeInTheDocument()
  })

  it('goes back to the previous tab', async () => {
    packageHandlers()
    const { user, router } = renderApp('/packages/my_company_core')
    await screen.findByRole('heading', { level: 1, name: /^my_company_core/ })
    await user.click(screen.getByRole('tab', { name: 'Versions' }))
    await user.click(screen.getByRole('tab', { name: 'Install' }))
    expect(where(router)).toBe('/packages/my_company_core?tab=install')

    await act(() => router.navigate(-1))
    expect(where(router)).toBe('/packages/my_company_core?tab=versions')
    expect(screen.getByRole('tab', { name: 'Versions', selected: true })).toBeInTheDocument()
    await act(() => router.navigate(-1))
    expect(screen.getByRole('tab', { name: 'README', selected: true })).toBeInTheDocument()
  })

  it('leaves the stats address for the other tabs', async () => {
    packageHandlers()
    const { user, router } = renderApp('/packages/my_company_core/stats')
    expect(await screen.findByRole('tab', { name: 'Stats', selected: true })).toBeInTheDocument()

    await user.click(screen.getByRole('tab', { name: 'README' }))
    expect(where(router)).toBe('/packages/my_company_core')
    expect(screen.getByRole('tab', { name: 'README', selected: true })).toBeInTheDocument()
    expect(screen.getByRole('document', { name: 'README' })).toBeInTheDocument()

    await act(() => router.navigate(-1))
    expect(await screen.findByRole('tab', { name: 'Stats', selected: true })).toBeInTheDocument()
    await user.click(screen.getByRole('tab', { name: 'Install' }))
    expect(where(router)).toBe('/packages/my_company_core?tab=install')
  })

  it('opens a tab from the URL', async () => {
    packageHandlers()
    renderApp('/packages/my_company_core?tab=install')
    expect(await screen.findByRole('tab', { name: 'Install', selected: true })).toBeInTheDocument()
  })

  it('selects a version from the sidebar', async () => {
    const requested = packageHandlers()
    const { user, router } = renderApp('/packages/my_company_core?tab=readme')
    const select = await screen.findByRole('combobox', { name: 'Show version' })
    expect(within(select).getByRole('option', { name: '1.0.0 (retracted)' })).toBeInTheDocument()
    expect(
      within(select).getByRole('option', { name: '2.0.0-beta.3 (prerelease)' }),
    ).toBeInTheDocument()

    await user.selectOptions(select, '1.0.0')
    expect(where(router)).toBe('/packages/my_company_core/versions/1.0.0?tab=readme')
    expect(await screen.findByRole('heading', { name: 'Version 1.0.0' })).toBeInTheDocument()
    expect(requested).toContain('my_company_core@1.0.0')
    expect(screen.getByText('Version 1.0.0 is retracted')).toBeInTheDocument()
  })

  it('shows a discontinued notice with the replacement', async () => {
    packageHandlers(f.pkg({ isDiscontinued: true, replacedBy: 'my_company_core2' }))
    renderApp('/packages/my_company_core')
    expect(await screen.findByText('This package is discontinued')).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'my_company_core2' })).toHaveAttribute(
      'href',
      '/packages/my_company_core2',
    )
  })

  it('shows a 404 page with search for an unknown package', async () => {
    packageHandlers()
    renderApp('/packages/missing')
    expect(
      await screen.findByRole('heading', { name: 'This package does not exist' }),
    ).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'pub.dev' })).toHaveAttribute(
      'href',
      'https://pub.dev/packages/missing',
    )
  })

  it('offers the actions menu to uploaders only', async () => {
    packageHandlers()
    renderApp('/packages/my_company_core', { me: f.me(f.user()) })
    expect(await screen.findByRole('button', { name: 'Actions' })).toBeInTheDocument()
  })

  it('hides the actions menu from others', async () => {
    packageHandlers()
    renderApp('/packages/my_company_core', { me: f.me(f.user({ email: 'other@company.example' })) })
    await screen.findByRole('heading', { level: 1, name: /^my_company_core/ })
    await waitFor(() => expect(screen.queryByRole('button', { name: 'Actions' })).toBeNull())
  })
})
