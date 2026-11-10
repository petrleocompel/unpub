import { screen } from '@testing-library/react'
import { http, HttpResponse } from 'msw'
import { describe, expect, it } from 'vitest'
import * as f from '../fixtures'
import { renderApp } from '../render'
import { server, url } from '../server'

describe('theme', () => {
  it('follows the system by default and cycles light, dark and system', async () => {
    server.use(http.get(url('/webapi/v2/packages'), () => HttpResponse.json(f.page([]))))
    const { user } = renderApp('/')
    const toggle = await screen.findByRole('button', { name: /System theme/ })
    expect(document.documentElement).not.toHaveClass('dark')

    await user.click(toggle)
    expect(localStorage.getItem('unpub-theme')).toBe('light')
    expect(document.documentElement).not.toHaveClass('dark')

    await user.click(screen.getByRole('button', { name: /^Light theme/ }))
    expect(localStorage.getItem('unpub-theme')).toBe('dark')
    expect(document.documentElement).toHaveClass('dark')

    await user.click(screen.getByRole('button', { name: /^Dark theme/ }))
    expect(localStorage.getItem('unpub-theme')).toBeNull()
    expect(document.documentElement).not.toHaveClass('dark')
  })

  it('starts from the stored choice', async () => {
    localStorage.setItem('unpub-theme', 'dark')
    server.use(http.get(url('/webapi/v2/packages'), () => HttpResponse.json(f.page([]))))
    renderApp('/')
    expect(await screen.findByRole('button', { name: /^Dark theme/ })).toBeInTheDocument()
    expect(document.documentElement).toHaveClass('dark')
  })
})
