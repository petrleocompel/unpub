import { act, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { CopyButton } from '@/components/copy-button'

describe('CopyButton', () => {
  beforeEach(() => {
    vi.useFakeTimers()
    Object.defineProperty(navigator, 'clipboard', {
      value: { writeText: vi.fn().mockResolvedValue(undefined) },
      configurable: true,
    })
  })
  afterEach(() => vi.useRealTimers())

  async function copy() {
    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: 'Copy the hash' }))
    })
  }

  it('says Copied for two seconds', async () => {
    render(<CopyButton text="abc" label="the hash" size="sm" />)
    await copy()
    expect(navigator.clipboard.writeText).toHaveBeenCalledWith('abc')
    expect(screen.getByRole('button')).toHaveTextContent('Copied')
    act(() => vi.advanceTimersByTime(1999))
    expect(screen.getByRole('button')).toHaveTextContent('Copied')
    act(() => vi.advanceTimersByTime(1))
    expect(screen.getByRole('button')).toHaveTextContent(/^Copy$/)
  })

  it('restarts the two seconds on a second copy', async () => {
    render(<CopyButton text="abc" label="the hash" size="sm" />)
    await copy()
    act(() => vi.advanceTimersByTime(1500))
    await copy()
    act(() => vi.advanceTimersByTime(1500))
    expect(screen.getByRole('button')).toHaveTextContent('Copied')
    expect(vi.getTimerCount()).toBe(1)
  })

  it('cancels the timeout when it goes away', async () => {
    const { unmount } = render(<CopyButton text="abc" label="the hash" size="sm" />)
    await copy()
    expect(vi.getTimerCount()).toBe(1)
    unmount()
    expect(vi.getTimerCount()).toBe(0)
  })
})
