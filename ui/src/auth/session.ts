import { useQuery } from '@tanstack/react-query'
import { configQuery, meQuery } from '@/api/queries'
import type { Config, Me, Package } from '@/api/types'

export type Session = {
  config: Config
  me: Me | null
  isAdmin: boolean
  /** A password login, as opposed to a token: needed to change credentials. */
  isSession: boolean
}

/** The config and the current user, loaded by the app shell before any page. */
export function useSession(): Session {
  const config = useQuery(configQuery).data
  const me = useQuery(meQuery).data ?? null
  if (!config) throw new Error('useSession before the config is loaded')
  return {
    config,
    me,
    isAdmin: me?.user.role === 'admin',
    isSession: !!me?.csrfToken,
  }
}

/** Whether [me] may retract, discontinue and manage the uploaders of [pkg]. */
export function canManage(me: Me | null, pkg: Pick<Package, 'uploaders' | 'private'>) {
  if (!me || !pkg.private) return false
  if (!me.scopes.includes('publish')) return false
  if (me.user.role === 'admin') return true
  if (me.user.role !== 'publisher') return false
  const email = me.user.email.toLowerCase()
  return pkg.uploaders.some((uploader) => uploader.toLowerCase() === email)
}

/** The URL `dart pub` uses for this server. */
export function hostedUrl(config: Config) {
  return (config.publicUrl ?? window.location.origin).replace(/\/+$/, '')
}
