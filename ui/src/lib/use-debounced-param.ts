import { useEffect, useRef, useState } from 'react'
import { useSearchParams } from 'react-router'

/**
 * A text field bound to the query parameter [name], written to the URL
 * [delay] ms after the last keystroke, resetting `page`.
 */
export function useDebouncedParam(name: string, delay = 300) {
  const [params, setParams] = useSearchParams()
  const value = params.get(name) ?? ''
  const [text, setText] = useState(value)
  const [seen, setSeen] = useState(value)
  const timer = useRef<number | undefined>(undefined)
  const latest = useRef(params)
  useEffect(() => {
    latest.current = params
  })

  // Follow changes of the URL made elsewhere (back, links, reset).
  if (seen !== value) {
    setSeen(value)
    setText(value)
  }
  useEffect(() => () => window.clearTimeout(timer.current), [])

  const change = (next: string) => {
    setText(next)
    window.clearTimeout(timer.current)
    timer.current = window.setTimeout(() => {
      const updated = new URLSearchParams(latest.current)
      if (next.trim()) updated.set(name, next.trim())
      else updated.delete(name)
      updated.delete('page')
      setParams(updated, { replace: true })
    }, delay)
  }
  return [text, change, value] as const
}
