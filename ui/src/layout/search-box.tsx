import { useEffect, useRef, useState } from 'react'
import { Search, X } from 'lucide-react'
import { useLocation, useNavigate, useSearchParams } from 'react-router'
import { Input } from '@/components/ui/input'
import { cn } from '@/lib/utils'

const listPaths = new Set(['/', '/packages'])
export const searchDebounceMs = 300

/** Whether a key event comes from a field the user types into. */
function typing(target: EventTarget | null) {
  if (!(target instanceof HTMLElement)) return false
  return (
    target.isContentEditable ||
    !!target.closest('[contenteditable]:not([contenteditable="false"])') ||
    target instanceof HTMLInputElement ||
    target instanceof HTMLTextAreaElement ||
    target instanceof HTMLSelectElement
  )
}

/** An open dialog, sheet or alert dialog: the shortcut stays inside it. */
const openDialog =
  '[aria-modal="true"], dialog[open], [role="dialog"]:not([data-state="closed"]), [role="alertdialog"]:not([data-state="closed"])'

/**
 * The search box of the header. On the package list it searches as you type,
 * keeping the query in the URL; elsewhere Enter opens the list. `/` focuses
 * it from anywhere, Esc clears it.
 */
export function SearchBox({ className }: { className?: string }) {
  const location = useLocation()
  const navigate = useNavigate()
  const [params] = useSearchParams()
  const onList = listPaths.has(location.pathname)
  const urlQuery = onList ? (params.get('q') ?? '') : ''
  const [value, setValue] = useState(urlQuery)
  const input = useRef<HTMLInputElement>(null)
  const timer = useRef<number | undefined>(undefined)
  // The location when the debounced search commits, not when it was typed.
  const current = useRef(location)
  useEffect(() => {
    current.current = location
  })

  // Follow the URL (back and forward, links) unless the user is typing.
  useEffect(() => {
    if (document.activeElement !== input.current || !onList) setValue(urlQuery)
  }, [urlQuery, onList])

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (
        event.key === '/' &&
        !event.metaKey &&
        !event.ctrlKey &&
        !event.altKey &&
        !typing(event.target) &&
        !typing(document.activeElement) &&
        !document.querySelector(openDialog)
      ) {
        event.preventDefault()
        input.current?.focus()
        input.current?.select()
      }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [])

  // Any navigation, and leaving, cancels a search still being typed.
  useEffect(() => () => window.clearTimeout(timer.current), [location.key])

  const go = (query: string, replace: boolean) => {
    const { pathname, search: currentSearch } = current.current
    const here = listPaths.has(pathname)
    const next = new URLSearchParams(here ? currentSearch : undefined)
    if (query.trim()) next.set('q', query.trim())
    else next.delete('q')
    next.delete('page')
    // Best match only exists with a query.
    if (!query.trim() && next.get('sort') === 'relevance') next.delete('sort')
    const search = next.toString()
    navigate(
      { pathname: here ? pathname : '/packages', search: search ? `?${search}` : '' },
      { replace },
    )
  }

  return (
    <form
      role="search"
      className={cn('relative w-full', className)}
      onSubmit={(event) => {
        event.preventDefault()
        window.clearTimeout(timer.current)
        go(value, false)
      }}
    >
      <label htmlFor="site-search" className="sr-only">
        Search packages
      </label>
      <Search
        aria-hidden
        className="pointer-events-none absolute top-1/2 left-2.5 size-4 -translate-y-1/2 text-muted-foreground"
      />
      <Input
        ref={input}
        id="site-search"
        type="search"
        value={value}
        placeholder="Search packages"
        autoComplete="off"
        spellCheck={false}
        aria-keyshortcuts="/"
        className="h-9.5 bg-surface pr-14 pl-8 [&::-webkit-search-cancel-button]:hidden"
        onChange={(event) => {
          const next = event.target.value
          setValue(next)
          if (onList) {
            window.clearTimeout(timer.current)
            timer.current = window.setTimeout(() => {
              if (listPaths.has(current.current.pathname)) go(next, true)
            }, searchDebounceMs)
          }
        }}
        onKeyDown={(event) => {
          if (event.key === 'Escape') {
            event.preventDefault()
            window.clearTimeout(timer.current)
            setValue('')
            if (onList && urlQuery) go('', true)
          }
        }}
      />
      {value ? (
        <button
          type="button"
          aria-label="Clear the search"
          className="absolute top-1/2 right-2 -translate-y-1/2 rounded-sm p-1 text-muted-foreground hover:text-foreground"
          onClick={() => {
            window.clearTimeout(timer.current)
            setValue('')
            if (onList && urlQuery) go('', true)
            input.current?.focus()
          }}
        >
          <X aria-hidden className="size-4" />
        </button>
      ) : (
        <kbd
          aria-hidden
          className="pointer-events-none absolute top-1/2 right-2 hidden -translate-y-1/2 rounded border bg-muted px-1.5 font-mono text-xs text-muted-foreground sm:block"
        >
          /
        </kbd>
      )}
    </form>
  )
}
