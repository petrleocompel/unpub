import createClient, { type Middleware } from 'openapi-fetch'
import type { paths } from './schema'
import type { ApiErrorBody } from './types'

/** An answer of the API that is not a success, or no answer at all. */
export class ApiError extends Error {
  readonly status: number
  readonly code: string
  /** Seconds, from `Retry-After` of a 429. */
  readonly retryAfter: number | null

  constructor(status: number, code: string, message: string, retryAfter: number | null = null) {
    super(message)
    this.name = 'ApiError'
    this.status = status
    this.code = code
    this.retryAfter = retryAfter
  }

  /** The request never got an answer: offline or the server is down. */
  get isNetwork() {
    return this.status === 0
  }
}

let csrfToken: string | null = null

/** The CSRF token of the session, sent with every change. */
export function setCsrfToken(token: string | null | undefined) {
  csrfToken = token ?? null
}

type UnauthorizedHandler = () => void
let onUnauthorized: UnauthorizedHandler = () => {}

/** What to do when a request answers 401: the app sends the user to log in. */
export function setUnauthorizedHandler(handler: UnauthorizedHandler) {
  onUnauthorized = handler
}

type NetworkListener = (reachable: boolean) => void
const networkListeners = new Set<NetworkListener>()

/** Called with false when a request fails without an answer, true on the next answer. */
export function onNetworkChange(listener: NetworkListener) {
  networkListeners.add(listener)
  return () => {
    networkListeners.delete(listener)
  }
}

function notifyNetwork(reachable: boolean) {
  for (const listener of networkListeners) listener(reachable)
}

/** Paths whose 401 is an answer, not an expired session. */
const quietUnauthorized = ['/webapi/me', '/webapi/login', '/webapi/logout', '/webapi/config']

const safeMethods = new Set(['GET', 'HEAD', 'OPTIONS'])

const middleware: Middleware = {
  onRequest({ request }) {
    if (!safeMethods.has(request.method) && csrfToken) {
      request.headers.set('X-CSRF-Token', csrfToken)
    }
    return request
  },
  onResponse({ request, response }) {
    notifyNetwork(true)
    if (response.status === 401) {
      const path = new URL(request.url).pathname
      if (!quietUnauthorized.includes(path)) onUnauthorized()
    }
    return response
  },
  onError({ error }) {
    notifyNetwork(false)
    return new ApiError(
      0,
      'network',
      error instanceof Error && error.name === 'AbortError'
        ? 'The request was cancelled.'
        : 'The server cannot be reached. Check your connection and try again.',
    )
  },
}

function origin() {
  return typeof window === 'undefined' ? 'http://localhost' : window.location.origin
}

/** The typed client of `docs/openapi.yaml`. Same origin, session cookie. */
export const api = createClient<paths>({
  baseUrl: origin(),
  credentials: 'same-origin',
  headers: { Accept: 'application/json' },
  // Resolved on every call, so tests can replace the global fetch.
  fetch: (request) => globalThis.fetch(request),
})
api.use(middleware)

type Result<T> = { data?: T; error?: unknown; response: Response }

/** The data of [result], or an [ApiError] made from its error body. */
export async function unwrap<T>(promise: Promise<Result<T>>): Promise<T> {
  let result: Result<T>
  try {
    result = await promise
  } catch (error) {
    if (error instanceof ApiError) throw error
    throw new ApiError(0, 'network', 'The server cannot be reached.')
  }
  if (result.error === undefined && result.response.ok) return result.data as T
  throw toApiError(result.response, result.error)
}

export function toApiError(response: Response, body: unknown): ApiError {
  const retry = response.headers.get('Retry-After')
  const retryAfter = retry && /^\d+$/.test(retry) ? Number(retry) : null
  const error = (body as Partial<ApiErrorBody> | undefined)?.error
  if (error && typeof error.message === 'string') {
    return new ApiError(response.status, error.code ?? 'error', error.message, retryAfter)
  }
  const text = typeof body === 'string' && body.length < 300 ? body : ''
  return new ApiError(
    response.status,
    statusCode(response.status),
    text || `The server answered ${response.status} ${response.statusText}`.trim(),
    retryAfter,
  )
}

function statusCode(status: number) {
  switch (status) {
    case 401:
      return 'unauthorized'
    case 403:
      return 'forbidden'
    case 404:
      return 'not_found'
    case 429:
      return 'rate_limited'
    default:
      return status >= 500 ? 'server_error' : 'error'
  }
}

/** A message for a toast or a form, from any error. */
export function errorMessage(error: unknown): string {
  if (error instanceof ApiError) {
    if (error.code === 'csrf_failed') {
      return 'Your session token is out of date. Reload the page and try again.'
    }
    if (error.status === 429 && error.retryAfter) {
      return `${error.message} Try again in ${formatWait(error.retryAfter)}.`
    }
    return error.message
  }
  if (error instanceof Error) return error.message
  return 'Something went wrong.'
}

export function formatWait(seconds: number) {
  if (seconds < 60) return `${seconds} second${seconds === 1 ? '' : 's'}`
  const minutes = Math.ceil(seconds / 60)
  return `${minutes} minute${minutes === 1 ? '' : 's'}`
}
