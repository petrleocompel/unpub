import { useLocation } from 'react-router'
import { useSession } from '@/auth/session'
import { classicUrl } from '@/lib/base'

export function Footer() {
  const { config } = useSession()
  const location = useLocation()
  // A full page load: the classic pages are not routes of the client.
  const classic = `${classicUrl(config.ui.classicPath, location.pathname)}${location.search}`
  return (
    <footer className="border-t">
      <div className="mx-auto flex max-w-7xl flex-wrap items-center gap-x-6 gap-y-2 px-4 py-6 text-sm text-muted-foreground">
        <span className="font-mono">unpub {config.version}</span>
        <a
          className="hover:text-foreground hover:underline"
          href="https://github.com/petrleocompel/unpub"
        >
          Source code
        </a>
        <a
          className="hover:text-foreground hover:underline"
          href={classic}
          data-testid="classic-link"
        >
          Classic version of this page
        </a>
        <a className="hover:text-foreground hover:underline" href="/webapi/openapi.yaml">
          API documentation
        </a>
      </div>
    </footer>
  )
}
