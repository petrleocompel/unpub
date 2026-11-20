import { http, HttpResponse, type JsonBodyType } from 'msw'
import { setupServer } from 'msw/node'
import type { Config, Me } from '@/api/types'
import * as f from './fixtures'

/** The URL of an API path, as the client asks for it in jsdom. */
export const url = (path: string) => new URL(path, window.location.origin).toString()

export function error(
  status: number,
  code: string,
  message: string,
  headers?: Record<string, string>,
) {
  return HttpResponse.json({ error: { code, message } }, { status, headers })
}

/** Handlers for the session: the config and who is logged in (null: nobody). */
export function sessionHandlers(me: Me | null, config: Config = f.config()) {
  return [
    http.get(url('/webapi/config'), () => HttpResponse.json(config)),
    http.get(url('/webapi/me'), () => HttpResponse.json(me ?? { user: null })),
  ]
}

export const server = setupServer(
  ...sessionHandlers(null),
  // The dashboard sidebar counts failed deliveries from the overview.
  http.get(url('/webapi/admin/overview'), () => HttpResponse.json(f.overview())),
)

/** Records the requests to [path] answered with [body]. */
export function capture(
  method: 'get' | 'post' | 'put' | 'patch' | 'delete',
  path: string,
  body: JsonBodyType | ((request: Request) => Response | Promise<Response>),
  status = 200,
) {
  const requests: Request[] = []
  server.use(
    http[method](url(path), async ({ request }) => {
      requests.push(request.clone())
      return typeof body === 'function' ? body(request) : HttpResponse.json(body, { status })
    }),
  )
  return requests
}
