import { screen, waitFor } from '@testing-library/react'
import { http, HttpResponse } from 'msw'
import { describe, expect, it } from 'vitest'
import * as f from '../fixtures'
import { renderApp, where } from '../render'
import { capture, error, server, url } from '../server'

describe('login', () => {
  it('logs in and goes back to the page in next', async () => {
    let loggedIn = false
    server.use(
      http.post(url('/webapi/login'), async ({ request }) => {
        const body = (await request.json()) as { email: string; password: string }
        if (body.password !== 'right-password')
          return error(401, 'invalid_credentials', 'Wrong email or password.')
        loggedIn = true
        return HttpResponse.json({ user: f.admin, csrfToken: 'csrf-1' })
      }),
    )
    const { user, router } = renderApp('/login?next=%2Fpackages%3Fq%3Dcore')
    // The session handler of renderApp answers 401 until the login succeeds.
    server.use(
      http.get(url('/webapi/me'), () =>
        loggedIn ? HttpResponse.json(f.me()) : error(401, 'unauthorized', 'No session.'),
      ),
      http.get(url('/webapi/v2/packages'), () => HttpResponse.json(f.page([]))),
    )

    await user.type(await screen.findByLabelText('Email'), 'admin@company.example')
    await user.type(screen.getByLabelText('Password'), 'wrong')
    await user.click(screen.getByRole('button', { name: 'Log in' }))
    const alert = await screen.findByRole('alert')
    expect(alert).toHaveTextContent('The email or the password is wrong.')
    expect(screen.getByLabelText('Password')).toHaveValue('')
    for (const field of [screen.getByLabelText('Email'), screen.getByLabelText('Password')]) {
      expect(field).toHaveAttribute('aria-invalid', 'true')
      expect(field).toHaveAttribute('aria-errormessage', alert.id)
      expect(field).toHaveAccessibleDescription('The email or the password is wrong.')
    }

    await user.type(screen.getByLabelText('Password'), 'right-password')
    await user.click(screen.getByRole('button', { name: 'Log in' }))
    await waitFor(() => expect(where(router)).toBe('/packages?q=core'))
    expect(
      await screen.findByRole('button', { name: 'Account menu for admin@company.example' }),
    ).toBeInTheDocument()
  })

  it('says how long to wait when rate limited', async () => {
    server.use(
      http.post(url('/webapi/login'), () =>
        error(429, 'rate_limited', 'Too many attempts.', { 'Retry-After': '120' }),
      ),
    )
    const { user } = renderApp('/login')
    await user.type(await screen.findByLabelText('Email'), 'a@b.example')
    await user.type(screen.getByLabelText('Password'), 'whatever1')
    await user.click(screen.getByRole('button', { name: 'Log in' }))
    expect(await screen.findByRole('alert')).toHaveTextContent(
      'Too many failed attempts. Try again in 2 minutes.',
    )
  })

  it('ignores a next that leaves the site', async () => {
    server.use(
      http.post(url('/webapi/login'), () => HttpResponse.json({ user: f.admin, csrfToken: 'c' })),
      http.get(url('/webapi/v2/packages'), () => HttpResponse.json(f.page([]))),
    )
    const { user, router } = renderApp('/login?next=%2F%2Fevil.example')
    await user.type(await screen.findByLabelText('Email'), 'admin@company.example')
    await user.type(screen.getByLabelText('Password'), 'right-password')
    server.use(http.get(url('/webapi/me'), () => HttpResponse.json(f.me())))
    await user.click(screen.getByRole('button', { name: 'Log in' }))
    await waitFor(() => expect(where(router)).toBe('/'))
  })

  it('sends a page that answers 401 to the login, with next', async () => {
    server.use(
      http.get(url('/webapi/tokens'), () => error(401, 'unauthorized', 'Session expired.')),
    )
    const { router } = renderApp('/account?page=2', { me: f.me() })
    await waitFor(() => expect(where(router)).toBe('/login?next=%2Faccount%3Fpage%3D2'))
    expect(await screen.findByRole('heading', { name: 'Log in to unpub' })).toBeInTheDocument()
  })

  it('sends anonymous visitors of the account page to the login', async () => {
    const { router } = renderApp('/account')
    await waitFor(() => expect(where(router)).toBe('/login?next=%2Faccount'))
  })
})

describe('logout', () => {
  function packages() {
    server.use(http.get(url('/webapi/v2/packages'), () => HttpResponse.json(f.page([]))))
  }

  async function logOut(user: ReturnType<typeof renderApp>['user']) {
    await user.click(
      await screen.findByRole('button', { name: 'Account menu for admin@company.example' }),
    )
    await user.click(await screen.findByRole('menuitem', { name: 'Log out' }))
  }

  it('ends the session', async () => {
    packages()
    const logouts = capture('post', '/webapi/logout', { done: true })
    const { user } = renderApp('/', { me: f.me() })
    await logOut(user)
    expect(await screen.findByText('Logged out')).toBeInTheDocument()
    expect(logouts).toHaveLength(1)
    expect(await screen.findByRole('link', { name: 'Log in' })).toBeInTheDocument()
  })

  it('reads the CSRF token again and retries once when it is refused', async () => {
    packages()
    const tokens: (string | null)[] = []
    server.use(
      http.post(url('/webapi/logout'), ({ request }) => {
        const token = request.headers.get('X-CSRF-Token')
        tokens.push(token)
        return token === 'csrf-new'
          ? HttpResponse.json({ done: true })
          : error(403, 'csrf_failed', 'CSRF token mismatch.')
      }),
    )
    const { user } = renderApp('/', { me: f.me(f.admin, 'csrf-old') })
    await screen.findByRole('button', { name: 'Account menu for admin@company.example' })
    server.use(http.get(url('/webapi/me'), () => HttpResponse.json(f.me(f.admin, 'csrf-new'))))
    await logOut(user)
    expect(await screen.findByText('Logged out')).toBeInTheDocument()
    expect(tokens).toEqual(['csrf-old', 'csrf-new'])
  })

  it('keeps the session when the logout fails', async () => {
    packages()
    const logouts = capture('post', '/webapi/logout', () =>
      error(403, 'csrf_failed', 'CSRF token mismatch.'),
    )
    const { user } = renderApp('/', { me: f.me() })
    await logOut(user)
    expect(await screen.findByText('Logging out failed')).toBeInTheDocument()
    // One retry with a fresh token, then the error.
    expect(logouts).toHaveLength(2)
    expect(
      screen.getByRole('button', { name: 'Account menu for admin@company.example' }),
    ).toBeInTheDocument()
    expect(screen.queryByRole('link', { name: 'Log in' })).toBeNull()
  })

  it('keeps the session when the server cannot be reached', async () => {
    packages()
    server.use(http.post(url('/webapi/logout'), () => HttpResponse.error()))
    const { user } = renderApp('/', { me: f.me(f.admin, 'csrf-xyz') })
    await logOut(user)
    expect(await screen.findByText('Logging out failed')).toBeInTheDocument()
    expect(
      screen.getByRole('button', { name: 'Account menu for admin@company.example' }),
    ).toBeInTheDocument()
    // The token still goes with the next change.
    const revoked = capture('delete', '/webapi/tokens/t1', { token: f.token() })
    server.use(http.get(url('/webapi/tokens'), () => HttpResponse.json(f.page([f.token()]))))
    await user.click(screen.getByRole('button', { name: 'Account menu for admin@company.example' }))
    await user.click(await screen.findByRole('menuitem', { name: 'Account' }))
    await user.click(await screen.findByRole('button', { name: 'Revoke laptop' }))
    await user.click(await screen.findByRole('button', { name: 'Revoke token' }))
    await waitFor(() => expect(revoked).toHaveLength(1))
    expect(revoked[0]!.headers.get('X-CSRF-Token')).toBe('csrf-xyz')
  })
})

describe('CSRF', () => {
  it('sends the token of the session with every change', async () => {
    server.use(http.get(url('/webapi/tokens'), () => HttpResponse.json(f.page([f.token()]))))
    const revoked = capture('delete', '/webapi/tokens/t1', {
      token: f.token({ revokedAt: '2026-11-10T00:00:00Z' }),
    })
    const { user } = renderApp('/account', { me: f.me(f.admin, 'csrf-xyz') })
    await user.click(await screen.findByRole('button', { name: 'Revoke laptop' }))
    await user.click(await screen.findByRole('button', { name: 'Revoke token' }))
    await waitFor(() => expect(revoked).toHaveLength(1))
    expect(revoked[0]!.headers.get('X-CSRF-Token')).toBe('csrf-xyz')
  })

  it('does not send it with reads', async () => {
    const reads = capture('get', '/webapi/v2/packages', f.page([]))
    renderApp('/', { me: f.me(f.admin, 'csrf-xyz') })
    await waitFor(() => expect(reads.length).toBeGreaterThan(0))
    expect(reads[0]!.headers.get('X-CSRF-Token')).toBeNull()
  })

  it('explains a refused token', async () => {
    server.use(
      http.get(url('/webapi/tokens'), () => HttpResponse.json(f.page([]))),
      http.post(url('/webapi/tokens'), () => error(403, 'csrf_failed', 'CSRF token missing.')),
    )
    const { user } = renderApp('/account', { me: f.me() })
    await user.type(await screen.findByLabelText('Name'), 'ci')
    await user.click(screen.getByRole('button', { name: 'Create token' }))
    expect(await screen.findByText(/session token is out of date/)).toBeInTheDocument()
  })
})

describe('private registry', () => {
  const privateConfig = f.config({ readAccess: 'authenticated' })

  it('shows anonymous visitors only the login', async () => {
    const { router } = renderApp('/packages/my_company_core', { config: privateConfig })
    expect(await screen.findByRole('heading', { name: 'Log in to unpub' })).toBeInTheDocument()
    expect(where(router)).toBe('/login?next=%2Fpackages%2Fmy_company_core')
    expect(screen.getByText(/This registry is private/)).toBeInTheDocument()
    expect(screen.queryByRole('searchbox')).toBeNull()
  })

  it('shows the pages once logged in', async () => {
    server.use(
      http.get(url('/webapi/v2/packages'), () =>
        HttpResponse.json(f.page([f.summary('my_company_core')])),
      ),
    )
    renderApp('/', { config: privateConfig, me: f.me(f.user({ role: 'reader' })) })
    expect(await screen.findByRole('link', { name: 'my_company_core' })).toBeInTheDocument()
  })
})

describe('admin pages', () => {
  it('are forbidden to other roles', async () => {
    renderApp('/admin/users', { me: f.me(f.user()) })
    expect(
      await screen.findByRole('heading', { name: 'You may not open this page' }),
    ).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Log in as an administrator' })).toBeInTheDocument()
  })
})
