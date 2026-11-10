import { screen, waitFor, within } from '@testing-library/react'
import { http, HttpResponse } from 'msw'
import { describe, expect, it } from 'vitest'
import * as f from '../fixtures'
import { renderApp, where } from '../render'
import { capture, error, server, url } from '../server'

describe('account', () => {
  it('creates a token and shows its secret once', async () => {
    let tokens = [f.token()]
    server.use(
      http.get(url('/webapi/tokens'), () => HttpResponse.json(f.page(tokens))),
      http.get(url('/webapi/v2/packages'), () => HttpResponse.json(f.page([]))),
    )
    const created = capture('post', '/webapi/tokens', () => {
      const token = f.token({ id: 't2', name: 'ci-read', scopes: ['read'] })
      tokens = [token, ...tokens]
      return HttpResponse.json({ token, secret: 'unpub_secret_value' }, { status: 201 })
    })
    const { user, router } = renderApp('/account', { me: f.me() })

    await user.type(await screen.findByLabelText('Name'), 'ci-read')
    await user.click(screen.getByRole('checkbox', { name: 'publish' }))
    await user.click(screen.getByRole('button', { name: '30 d' }))
    expect(screen.getByRole('button', { name: '30 d' })).toHaveAttribute('aria-pressed', 'true')
    await user.click(screen.getByRole('button', { name: 'Create token' }))

    const box = await screen.findByRole('status', { name: /ci-read/ })
    expect(within(box).getByText('unpub_secret_value')).toBeInTheDocument()
    expect(
      within(box).getByText(/dart pub token add https:\/\/pub.example.com/),
    ).toBeInTheDocument()
    expect(within(box).getByText(/will not be shown again/)).toBeInTheDocument()
    expect(await created[0]!.json()).toEqual({
      name: 'ci-read',
      scopes: ['read'],
      expiresIn: '30d',
    })
    expect(await screen.findByRole('cell', { name: 'ci-read' })).toBeInTheDocument()

    // Leaving the page forgets the secret.
    await user.click(screen.getByRole('link', { name: 'Packages' }))
    await waitFor(() => expect(where(router)).toBe('/packages'))
    await router.navigate('/account')
    await screen.findByRole('cell', { name: 'ci-read' })
    expect(screen.queryByText('unpub_secret_value')).toBeNull()
  })

  it('limits readers to read tokens', async () => {
    server.use(http.get(url('/webapi/tokens'), () => HttpResponse.json(f.page([]))))
    renderApp('/account', { me: f.me(f.user({ role: 'reader' })) })
    expect(await screen.findByRole('checkbox', { name: 'publish' })).toBeDisabled()
    expect(screen.getByRole('checkbox', { name: 'read' })).toBeChecked()
    expect(screen.getByText('As a reader you can create read tokens only.')).toBeInTheDocument()
  })

  it('changes the password and says other sessions end', async () => {
    server.use(http.get(url('/webapi/tokens'), () => HttpResponse.json(f.page([]))))
    const changed = capture('post', '/webapi/me/password', { success: true })
    const { user } = renderApp('/account', { me: f.me() })
    await user.type(await screen.findByLabelText('Current password'), 'old-password')
    await user.type(screen.getByLabelText('New password'), 'new-password-1')
    await user.type(screen.getByLabelText('Repeat new password'), 'new-password-2')
    await user.click(screen.getByRole('button', { name: 'Change password' }))
    expect(await screen.findByText('The new passwords do not match.')).toBeInTheDocument()
    expect(screen.getByLabelText('Repeat new password')).toHaveAccessibleErrorMessage(
      'The new passwords do not match.',
    )
    expect(screen.getByLabelText('Current password')).not.toHaveAttribute('aria-invalid')
    expect(changed).toHaveLength(0)

    await user.clear(screen.getByLabelText('Repeat new password'))
    await user.type(screen.getByLabelText('Repeat new password'), 'new-password-1')
    await user.click(screen.getByRole('button', { name: 'Change password' }))
    expect(await screen.findByText('Your other sessions have been logged out.')).toBeInTheDocument()
    expect(await changed[0]!.json()).toEqual({
      currentPassword: 'old-password',
      newPassword: 'new-password-1',
    })
  })

  it('reports a wrong current password', async () => {
    server.use(
      http.get(url('/webapi/tokens'), () => HttpResponse.json(f.page([]))),
      http.post(url('/webapi/me/password'), () =>
        error(403, 'invalid_credentials', 'Wrong password.'),
      ),
    )
    const { user } = renderApp('/account', { me: f.me() })
    await user.type(await screen.findByLabelText('Current password'), 'nope')
    await user.type(screen.getByLabelText('New password'), 'new-password-1')
    await user.type(screen.getByLabelText('Repeat new password'), 'new-password-1')
    await user.click(screen.getByRole('button', { name: 'Change password' }))
    expect(await screen.findByText('The current password is wrong.')).toBeInTheDocument()
    expect(screen.getByLabelText('Current password')).toHaveAccessibleErrorMessage(
      'The current password is wrong.',
    )
  })
})
