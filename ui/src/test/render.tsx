import { render } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { createMemoryRouter } from 'react-router'
import { App, createQueryClient } from '@/app'
import type { Config, Me } from '@/api/types'
import { routes } from '@/routes'
import * as f from './fixtures'
import { server, sessionHandlers } from './server'

/** Renders the whole client at [path], with [me] logged in (null: nobody). */
export function renderApp(
  path: string,
  { me = null, config = f.config() }: { me?: Me | null; config?: Config } = {},
) {
  server.use(...sessionHandlers(me, config))
  const router = createMemoryRouter(routes, { initialEntries: [path] })
  const queryClient = createQueryClient()
  queryClient.setDefaultOptions({
    queries: { ...queryClient.getDefaultOptions().queries, retry: false },
  })
  const user = userEvent.setup()
  const view = render(<App router={router} queryClient={queryClient} />)
  return { ...view, router, user, queryClient }
}

/** The current path and query of [router]. */
export function where(router: ReturnType<typeof createMemoryRouter>) {
  const { pathname, search } = router.state.location
  return `${pathname}${search}`
}
