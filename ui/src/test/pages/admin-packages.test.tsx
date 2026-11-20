import { screen, waitFor, within } from '@testing-library/react'
import { http, HttpResponse } from 'msw'
import { describe, expect, it } from 'vitest'
import { shortUploaders } from '@/pages/admin/packages'
import * as f from '../fixtures'
import { renderApp, where } from '../render'
import { capture, server, url } from '../server'

describe('package moderation', () => {
  it('lists packages with their versions and uploaders', async () => {
    server.use(
      http.get(url('/webapi/v2/packages'), ({ request }) => {
        const params = new URL(request.url).searchParams
        expect(params.get('discontinued')).toBe('true')
        return HttpResponse.json(
          f.page([
            f.summary('my_company_core', {
              versionCount: 7,
              uploaders: ['a@x.example', 'b@x.example'],
            }),
          ]),
        )
      }),
    )
    renderApp('/admin/packages', { me: f.me() })
    const link = await screen.findByRole('link', { name: 'my_company_core' })
    expect(link).toHaveAttribute('href', '/admin/packages/my_company_core')
    const row = link.closest('tr')!
    expect(within(row).getByText('7')).toBeInTheDocument()
    expect(within(row).getByRole('button', { name: /^a, b/ })).toBeInTheDocument()
    expect(screen.getByRole('columnheader', { name: 'Name' })).toHaveAttribute(
      'aria-sort',
      'ascending',
    )
  })

  it('shortens long uploader lists', () => {
    expect(shortUploaders(['a@x.example'])).toBe('a')
    expect(shortUploaders(['a@x.example', 'b@x.example', 'c@x.example'])).toBe('a +2')
    // A name two uploaders share keeps its domain.
    expect(shortUploaders(['alice@company.example', 'alice@contractor.example'])).toBe(
      'alice@company.example, alice@contractor.example',
    )
  })

  it('shows every full uploader address from the keyboard', async () => {
    server.use(
      http.get(url('/webapi/v2/packages'), () =>
        HttpResponse.json(
          f.page([
            f.summary('my_company_core', {
              uploaders: [
                'alice@company.example',
                'alice@contractor.example',
                'bob@company.example',
              ],
            }),
          ]),
        ),
      ),
    )
    const { user } = renderApp('/admin/packages', { me: f.me() })
    const row = (await screen.findByRole('link', { name: 'my_company_core' })).closest('tr')!
    const toggle = within(row).getByRole('button', { name: /show the addresses/ })
    expect(toggle).toHaveAttribute('aria-expanded', 'false')
    expect(within(row).queryByRole('list')).not.toBeInTheDocument()

    toggle.focus()
    await user.keyboard('{Enter}')
    expect(toggle).toHaveAttribute('aria-expanded', 'true')
    expect(toggle).toHaveAccessibleName(/hide the addresses/)
    const list = within(row).getByRole('list')
    expect(
      within(list)
        .getAllByRole('listitem')
        .map((item) => item.textContent),
    ).toEqual(['alice@company.example', 'alice@contractor.example', 'bob@company.example'])

    await user.keyboard(' ')
    expect(toggle).toHaveAttribute('aria-expanded', 'false')
    expect(within(row).queryByRole('list')).not.toBeInTheDocument()
  })

  it('shows the full address of who published a version', async () => {
    server.use(
      http.get(url('/webapi/package/:name'), () =>
        HttpResponse.json({
          data: f.pkg({
            versions: [
              f.version('1.4.0', { uploader: 'alice@company.example' }),
              f.version('1.3.0', { uploader: 'alice@contractor.example' }),
            ],
          }),
        }),
      ),
    )
    renderApp('/admin/packages/my_company_core', { me: f.me() })
    const first = (await screen.findByRole('link', { name: '1.4.0' })).closest('tr')!
    const second = screen.getByRole('link', { name: '1.3.0' }).closest('tr')!
    expect(first).toHaveTextContent('alice@company.example')
    expect(second).toHaveTextContent('alice@contractor.example')
  })

  it('deletes a package only after typing its name', async () => {
    server.use(
      http.get(url('/webapi/package/:name'), () => HttpResponse.json({ data: f.pkg() })),
      http.get(url('/webapi/v2/packages'), () => HttpResponse.json(f.page([]))),
    )
    const deleted = capture('delete', '/api/packages/my_company_core', {
      success: { message: 'Deleted.' },
    })
    const { user, router } = renderApp('/admin/packages/my_company_core', { me: f.me() })

    await user.click(await screen.findByRole('button', { name: 'Delete package…' }))
    const dialog = await screen.findByRole('dialog', { name: 'Delete my_company_core?' })
    const confirm = within(dialog).getByRole('button', { name: 'Delete package' })
    expect(confirm).toBeDisabled()

    await user.type(
      within(dialog).getByLabelText(/Type my_company_core to confirm/),
      'my_company_cor',
    )
    expect(confirm).toBeDisabled()
    await user.type(within(dialog).getByLabelText(/Type my_company_core to confirm/), 'e')
    expect(confirm).toBeEnabled()
    await user.click(confirm)

    await waitFor(() => expect(deleted).toHaveLength(1))
    expect(deleted[0]!.headers.get('X-CSRF-Token')).toBe('csrf-123')
    await waitFor(() => expect(where(router)).toBe('/admin/packages'))
  })

  it('transfers ownership only with the box ticked', async () => {
    server.use(http.get(url('/webapi/package/:name'), () => HttpResponse.json({ data: f.pkg() })))
    const transferred = capture('put', '/api/packages/my_company_core/owner', {
      success: { message: 'Done.' },
    })
    const { user } = renderApp('/admin/packages/my_company_core', { me: f.me() })

    await user.click(await screen.findByRole('button', { name: 'Transfer…' }))
    const dialog = await screen.findByRole('dialog')
    await user.type(within(dialog).getByLabelText('New owner'), 'new.owner@company.example')
    const confirm = within(dialog).getByRole('button', { name: 'Transfer ownership' })
    expect(confirm).toBeDisabled()
    await user.click(within(dialog).getByRole('checkbox'))
    await user.click(confirm)
    await waitFor(() => expect(transferred).toHaveLength(1))
    expect(await transferred[0]!.json()).toEqual({ email: 'new.owner@company.example' })
  })

  it('retracts a version from the package page menu', async () => {
    server.use(http.get(url('/webapi/package/:name'), () => HttpResponse.json({ data: f.pkg() })))
    const retracted = capture('post', '/api/packages/my_company_core/versions/1.4.0/retract', {
      success: { message: 'Retracted.' },
    })
    const { user } = renderApp('/packages/my_company_core', { me: f.me(f.user()) })
    await user.click(await screen.findByRole('button', { name: 'Actions' }))
    // Uploaders who are not administrators get no delete actions.
    expect(screen.queryByRole('menuitem', { name: /Delete/ })).toBeNull()
    await user.click(screen.getByRole('menuitem', { name: 'Retract this version…' }))
    const dialog = await screen.findByRole('dialog')
    await user.click(within(dialog).getByRole('button', { name: 'Retract version' }))
    await waitFor(() => expect(retracted).toHaveLength(1))
    expect(await screen.findByText('Retracted 1.4.0')).toBeInTheDocument()
  })

  it('discontinues with a replacement', async () => {
    server.use(http.get(url('/webapi/package/:name'), () => HttpResponse.json({ data: f.pkg() })))
    const discontinued = capture('put', '/api/packages/my_company_core/discontinue', {
      success: { message: 'Done.' },
    })
    const { user } = renderApp('/admin/packages/my_company_core', { me: f.me() })
    await user.click(await screen.findByRole('checkbox', { name: 'Discontinued' }))
    await user.type(screen.getByLabelText('Replaced by (optional)'), 'my_company_core2')
    await user.click(screen.getByRole('button', { name: 'Save' }))
    await waitFor(() => expect(discontinued).toHaveLength(1))
    expect(await discontinued[0]!.json()).toEqual({
      isDiscontinued: true,
      replacedBy: 'my_company_core2',
    })
  })
})
