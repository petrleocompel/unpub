import { useEffect, useState } from 'react'
import { WifiOff } from 'lucide-react'
import { onNetworkChange } from '@/api/client'

/** Shown while the browser is offline or the last request got no answer. */
export function OfflineBanner() {
  const [online, setOnline] = useState(() => typeof navigator === 'undefined' || navigator.onLine)
  const [reachable, setReachable] = useState(true)

  useEffect(() => {
    const up = () => setOnline(true)
    const down = () => setOnline(false)
    window.addEventListener('online', up)
    window.addEventListener('offline', down)
    const unsubscribe = onNetworkChange(setReachable)
    return () => {
      window.removeEventListener('online', up)
      window.removeEventListener('offline', down)
      unsubscribe()
    }
  }, [])

  if (online && reachable) return null
  return (
    <div
      role="status"
      className="border-b border-warning/40 bg-[color-mix(in_oklab,var(--warning)_16%,var(--background))]"
    >
      <p className="mx-auto flex max-w-7xl items-center gap-2.5 px-4 py-2.5 text-[0.8125rem] font-medium sm:px-6">
        <WifiOff aria-hidden className="size-4 shrink-0 text-warning" />
        {online
          ? 'The server cannot be reached. What you see may be out of date.'
          : 'You are offline. What you see may be out of date.'}
      </p>
    </div>
  )
}
