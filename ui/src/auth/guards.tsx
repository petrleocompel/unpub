import type { ReactNode } from 'react'
import { Navigate, useLocation } from 'react-router'
import { ForbiddenPage } from '@/pages/errors'
import { useSession } from './session'

function LoginRedirect() {
  const location = useLocation()
  return (
    <Navigate
      to={`/login?next=${encodeURIComponent(`${location.pathname}${location.search}`)}`}
      replace
    />
  )
}

export function RequireLogin({ children }: { children: ReactNode }) {
  const { me } = useSession()
  return me ? children : <LoginRedirect />
}

export function RequireAdmin({ children }: { children: ReactNode }) {
  const { me, isAdmin } = useSession()
  if (!me) return <LoginRedirect />
  return isAdmin ? children : <ForbiddenPage />
}
