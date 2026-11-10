import { screen, waitFor, within } from '@testing-library/react'
import { http, HttpResponse } from 'msw'
import { describe, expect, it } from 'vitest'
import type { User } from '@/api/types'
import * as f from '../fixtures'
import { renderApp, where } from '../render'
import { error, server, url } from '../server'

function usersApi(initial: User[]) {
  let users = initial
  const patches: { id: string; body: unknown; csrf: string | null }[] = []
  const creates: unknown[] = []
  const searches: string[] = []
  server.use(
    http.get(url('/webapi/users'), ({ request }) => {
      const q = new URL(request.url).searchParams.get('q') ?? ''
      searches.push(q)
      return HttpResponse.json(
        f.page(
          users.filter((u) => u.email.includes(q)),
          1,
          50,
        ),
      )
    }),
    http.post(url('/webapi/users'), async ({ request }) => {
      const body = (await request.json()) as Partial<User>
      creates.push(body)
      const created = f.user({
        id: `u${users.length + 1}`,
        email: body.email!,
        role: body.role!,
        displayName: body.displayName ?? '',
      })
      users = [...users, created]
      return HttpResponse.json({ user: created }, { status: 201 })
    }),
    http.patch(url('/webapi/users/:id'), async ({ request, params }) => {
      const body = (await request.json()) as Partial<User>
      patches.push({ id: `${params.id}`, body, csrf: request.headers.get('X-CSRF-Token') })
      if (params.id === 'admin' && (body.role !== undefined || body.disabled)) {
        return error(409, 'last_admin', 'The last administrator cannot be demoted or disabled.')
      }
      users = users.map((u) => (u.id === params.id ? { ...u, ...body } : u))
      return HttpResponse.json({ user: users.find((u) => u.id === params.id) })
    }),
  )
  return { patches, creates, searches }
}

describe('admin users', () => {
  it('searches users through the URL', async () => {
    const api = usersApi([f.admin, f.user()])
    const { user, router } = renderApp('/admin/users', { me: f.me() })
    await screen.findByRole('cell', { name: 'jane.doe@company.example' })
    await user.type(screen.getByRole('searchbox', { name: 'Search users' }), 'jane')
    await waitFor(() => expect(where(router)).toBe('/admin/users?q=jane'))
    await waitFor(() => expect(api.searches.at(-1)).toBe('jane'))
    await waitFor(() =>
      expect(screen.queryByRole('cell', { name: /^admin@company.example/ })).toBeNull(),
    )
  })

  it('creates a user', async () => {
    const api = usersApi([f.admin])
    const { user } = renderApp('/admin/users', { me: f.me() })
    await user.click(await screen.findByRole('button', { name: 'Create user' }))
    const dialog = await screen.findByRole('dialog')
    await user.type(within(dialog).getByLabelText('Email'), 'new.dev@company.example')
    await user.type(within(dialog).getByLabelText('Display name (optional)'), 'New Dev')
    await user.selectOptions(within(dialog).getByLabelText('Role'), 'reader')
    await user.type(within(dialog).getByLabelText('Initial password (optional)'), 'initial-pass')
    await user.click(within(dialog).getByRole('button', { name: 'Create user' }))

    await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull())
    expect(api.creates).toEqual([
      {
        email: 'new.dev@company.example',
        role: 'reader',
        displayName: 'New Dev',
        password: 'initial-pass',
      },
    ])
    expect(await screen.findByRole('cell', { name: 'new.dev@company.example' })).toBeInTheDocument()
  })

  it('changes a role', async () => {
    const api = usersApi([f.admin, f.user()])
    const { user } = renderApp('/admin/users', { me: f.me() })
    await user.click(
      await screen.findByRole('button', { name: 'Actions for jane.doe@company.example' }),
    )
    await user.click(await screen.findByRole('menuitem', { name: 'Change role…' }))
    const dialog = await screen.findByRole('dialog')
    await user.selectOptions(within(dialog).getByLabelText('Role'), 'admin')
    await user.click(within(dialog).getByRole('button', { name: 'Change role' }))
    await waitFor(() => expect(api.patches).toHaveLength(1))
    expect(api.patches[0]).toEqual({ id: 'u1', body: { role: 'admin' }, csrf: 'csrf-123' })
    expect(await screen.findByText('jane.doe@company.example is now an admin')).toBeInTheDocument()
  })

  it('disables a user after confirming', async () => {
    const api = usersApi([f.admin, f.user()])
    const { user } = renderApp('/admin/users', { me: f.me() })
    await user.click(
      await screen.findByRole('button', { name: 'Actions for jane.doe@company.example' }),
    )
    await user.click(await screen.findByRole('menuitem', { name: 'Disable…' }))
    const dialog = await screen.findByRole('dialog', { name: 'Disable jane.doe@company.example?' })
    await user.click(within(dialog).getByRole('button', { name: 'Disable user' }))
    await waitFor(() => expect(api.patches[0]?.body).toEqual({ disabled: true }))
    const row = (await screen.findByRole('cell', { name: 'jane.doe@company.example' })).closest(
      'tr',
    )!
    expect(await within(row).findByText('Disabled')).toBeInTheDocument()
  })

  it('shows why the last administrator cannot be disabled', async () => {
    usersApi([f.admin])
    const { user } = renderApp('/admin/users', { me: f.me() })
    await user.click(
      await screen.findByRole('button', { name: 'Actions for admin@company.example' }),
    )
    await user.click(await screen.findByRole('menuitem', { name: 'Disable…' }))
    const dialog = await screen.findByRole('dialog')
    await user.click(within(dialog).getByRole('button', { name: 'Disable user' }))
    expect(await within(dialog).findByRole('alert')).toHaveTextContent(
      'The last administrator cannot be demoted or disabled. Make another user an administrator first.',
    )
  })
})
