import { useLocation } from 'react-router'
import { useSession } from '@/auth/session'
import { classicUrl } from '@/lib/base'

export function Footer() {
  const { config } = useSession()
  const location = useLocation()
  // A full page load: the classic pages are not routes of the client.
  const classic = `${classicUrl(config.ui.classicPath, location.pathname)}${location.search}`
  return (
    <footer className="border-t bg-surface">
      <div className="mx-auto flex max-w-7xl flex-wrap items-center gap-x-4 gap-y-1.5 px-4 py-4.5 text-xs text-muted-foreground sm:gap-x-6 sm:gap-y-2 sm:px-6 sm:text-[0.8125rem]">
        <span className="font-mono">unpub {config.version}</span>
        <a
          className="hover:text-foreground hover:underline hover:underline-offset-3"
          href="https://github.com/petrleocompel/unpub"
        >
          Source
        </a>
        <a
          className="hover:text-foreground hover:underline hover:underline-offset-3"
          href={classic}
          data-testid="classic-link"
        >
          Classic version
        </a>
        <a
          className="hover:text-foreground hover:underline hover:underline-offset-3"
          href="/webapi/openapi.yaml"
        >
          API docs
        </a>
      </div>
    </footer>
  )
}
