// Where the client and the server-rendered pages live, from the meta tags the
// server adds to index.html (see README, "Web client"). The development
// server of Vite adds none: the client is then at / and the classic pages
// are proxied under /classic.

function meta(name: string): string | null {
  if (typeof document === 'undefined') return null
  return document.querySelector<HTMLMetaElement>(`meta[name="${name}"]`)?.content ?? null
}

function normalize(path: string) {
  return path === '/' ? '' : path.replace(/\/+$/, '')
}

/** The base path of the client, `""` at the root or such as `/app`. */
export const basePath = normalize(meta('unpub-base') ?? '')

/** The base path of the server-rendered pages, `""` or `/classic`. */
export const initialClassicPath = normalize(meta('unpub-classic') ?? '/classic')

/** The URL of [path] (a client route such as `/packages/x`) in the classic UI. */
export function classicUrl(classicPath: string, path: string) {
  const prefix = normalize(classicPath)
  if (path === '/' || path === '') return prefix ? `${prefix}/` : '/'
  return `${prefix}${path}`
}

/** Whether [next] is a path on this site, safe to redirect to after login. */
export function isSafeNext(next: string | null | undefined): next is string {
  return !!next && next.startsWith('/') && !next.startsWith('//') && !next.startsWith('/\\')
}
